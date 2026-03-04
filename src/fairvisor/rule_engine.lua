local floor = math.floor
local pairs = pairs
local pcall = pcall
local tostring = tostring
local type = type

local utils = require("fairvisor.utils")

local _M = {}

local function _log_warn(...)
  if ngx and ngx.log then ngx.log(ngx.WARN, ...) end
end
local function _log_debug(...)
  if ngx and ngx.log then ngx.log(ngx.DEBUG, ...) end
end

local _dict = nil
local _health = nil

local _descriptor = nil
local _token_bucket = nil
local _cost_budget = nil
local _loop_detector = nil
local _circuit_breaker = nil
local _kill_switch = nil
local _shadow_mode = nil
local _llm_limiter = nil
local _last_global_shadow_active = nil
local _last_kill_switch_override_active = nil

local function _ensure_dependencies()
  if _descriptor then
    return
  end

  _descriptor = utils.safe_require("fairvisor.descriptor") or {}
  _token_bucket = utils.safe_require("fairvisor.token_bucket") or {}
  _cost_budget = utils.safe_require("fairvisor.cost_budget") or {}
  _loop_detector = utils.safe_require("fairvisor.loop_detector") or {}
  _circuit_breaker = utils.safe_require("fairvisor.circuit_breaker") or {}
  _kill_switch = utils.safe_require("fairvisor.kill_switch") or {}
  _shadow_mode = utils.safe_require("fairvisor.shadow_mode") or {}
  _llm_limiter = utils.safe_require("fairvisor.llm_limiter") or {}
end

local function _call(fn, default, ...)
  if type(fn) == "function" then
    return fn(...)
  end
  return default
end

local function _build_missing_set(missing_keys)
  local missing_set = {}
  for i = 1, #missing_keys do
    missing_set[missing_keys[i]] = true
  end
  return missing_set
end

local function _collect_limit_keys(policy)
  local keys = {}
  local seen = {}
  local rules = policy and policy.spec and policy.spec.rules or {}

  for i = 1, #rules do
    local limit_keys = rules[i].limit_keys or {}
    for j = 1, #limit_keys do
      local key = limit_keys[j]
      if key and not seen[key] then
        seen[key] = true
        keys[#keys + 1] = key
      end
    end
  end

  local fallback_limit = policy and policy.spec and policy.spec.fallback_limit
  if fallback_limit and fallback_limit.limit_keys then
    for i = 1, #fallback_limit.limit_keys do
      local key = fallback_limit.limit_keys[i]
      if key and not seen[key] then
        seen[key] = true
        keys[#keys + 1] = key
      end
    end
  end

  return keys
end

local function _inc_metric(name, value, labels)
  if _health and type(_health.inc) == "function" then
    pcall(function()
      _health:inc(name, labels or {}, value)
    end)
  end
end

local function _set_metric(name, labels, value)
  if _health and type(_health.set) == "function" then
    pcall(function()
      _health:set(name, labels or {}, value)
    end)
  end
end

local function _log_missing_descriptors(rule_missing, request_context)
  for i = 1, #rule_missing do
    _log_warn("evaluate reason=descriptor_missing key=", rule_missing[i], " path=", request_context and request_context.path or "")
    _inc_metric("fairvisor_descriptor_missing_total", 1, { key = rule_missing[i] })
  end
end

local function _parse_key(key)
  if _descriptor and type(_descriptor.parse_key) == "function" then
    return _descriptor.parse_key(key)
  end

  if type(key) ~= "string" then
    return nil, nil
  end

  local sep = string.find(key, ":", 1, true)
  if not sep then
    return nil, nil
  end

  return string.sub(key, 1, sep - 1), string.sub(key, sep + 1)
end

local function _match_claims(match, descriptors, request_context)
  for key, expected_value in pairs(match) do
    local actual = descriptors[key]

    if actual == nil then
      local source, name = _parse_key(key)
      if source == "jwt" then
        local claims = request_context and request_context.jwt_claims
        actual = claims and claims[name]
      end
    end

    if actual == nil or tostring(actual) ~= tostring(expected_value) then
      return false
    end
  end

  return true
end

local function _find_matching_rules(rules, request_context, descriptors)
  local matched = {}

  for i = 1, #rules do
    local rule = rules[i]
    if rule.match == nil or _match_claims(rule.match, descriptors, request_context) then
      matched[#matched + 1] = rule
    end
  end

  return matched
end

local function _check_missing_keys(limit_keys, missing_set)
  local missing = {}

  for i = 1, #limit_keys do
    local key = limit_keys[i]
    if missing_set[key] then
      missing[#missing + 1] = key
    end
  end

  return missing
end

local function _collect_kill_switch_scope_keys(kill_switches)
  local keys = {}
  local seen = {}

  for i = 1, #kill_switches do
    local kill_switch = kill_switches[i]
    local scope_key = kill_switch and kill_switch.scope_key
    if type(scope_key) == "string" and scope_key ~= "" and not seen[scope_key] then
      seen[scope_key] = true
      keys[#keys + 1] = scope_key
    end
  end

  return keys
end

local function _dedupe_policy_ids(policy_ids)
  local unique = {}
  local seen = {}

  for i = 1, #policy_ids do
    local policy_id = policy_ids[i]
    if policy_id ~= nil and not seen[policy_id] then
      seen[policy_id] = true
      unique[#unique + 1] = policy_id
    end
  end

  return unique
end

local function _build_counter_key(rule, composite_key)
  local rule_name = rule.name or "rule"
  local algorithm = rule.algorithm

  if algorithm == "token_bucket" then
    return _call(_token_bucket.build_key, "tb:" .. rule_name .. ":" .. tostring(composite_key or ""), rule_name, composite_key)
  end

  if algorithm == "cost_based" then
    return _call(_cost_budget.build_key, "cb:" .. rule_name .. ":" .. tostring(composite_key or ""), rule_name, composite_key)
  end

  if algorithm == "token_bucket_llm" then
    return "llm:" .. rule_name .. ":" .. tostring(composite_key or "")
  end

  return "rule:" .. rule_name .. ":" .. tostring(composite_key or "")
end

local function _dispatch_limiter(dict, rule, key, request_context, now)
  local algorithm = rule.algorithm
  local config = rule.algorithm_config or {}

  if algorithm == "token_bucket" then
    local cost = _call(_token_bucket.resolve_cost, 1, config, request_context)
    return _call(_token_bucket.check, { allowed = true }, dict, key, config, cost)
  end

  if algorithm == "cost_based" then
    local cost = _call(_cost_budget.resolve_cost, 1, config, request_context)
    return _call(_cost_budget.check, { allowed = true }, dict, key, config, cost, now)
  end

  if algorithm == "token_bucket_llm" then
    return _call(_llm_limiter.check, { allowed = true }, dict, key, config, request_context, now)
  end

  return { allowed = true }
end

-- Circuit breaker cost is derived from the first rule of the policy.
local function _resolve_request_cost(policy, request_context)
  local rules = policy and policy.spec and policy.spec.rules or {}
  local rule = rules[1]
  if not rule then
    return 1
  end

  local config = rule.algorithm_config or {}

  if rule.algorithm == "token_bucket" then
    return _call(_token_bucket.resolve_cost, 1, config, request_context)
  end

  if rule.algorithm == "cost_based" then
    return _call(_cost_budget.resolve_cost, 1, config, request_context)
  end

  if rule.algorithm == "token_bucket_llm" then
    return request_context and request_context.max_tokens or 1
  end

  return 1
end

local function _build_cb_limit_key(descriptors, policy)
  local rules = policy and policy.spec and policy.spec.rules or {}
  local primary_limit_key = nil

  for i = 1, #rules do
    local rule = rules[i]
    if rule.limit_keys and rule.limit_keys[1] then
      primary_limit_key = rule.limit_keys[1]
      break
    end
  end

  if not primary_limit_key then
    return "cb:" .. tostring(policy and policy.id or "policy")
  end

  local composite_key
  if _descriptor and type(_descriptor.build_composite_key) == "function" then
    composite_key = _descriptor.build_composite_key({ primary_limit_key }, descriptors)
  else
    composite_key = tostring(descriptors[primary_limit_key] or "")
  end

  return "cb:" .. tostring(policy and policy.id or "policy") .. ":" .. tostring(composite_key or "")
end

local function _apply_limit_headers(headers, limit_result, policy_name)
  if not limit_result then
    return
  end

  if limit_result.limit ~= nil then
    headers["RateLimit-Limit"] = tostring(limit_result.limit)
  end

  if limit_result.remaining ~= nil then
    headers["RateLimit-Remaining"] = tostring(limit_result.remaining)
  end

  local reset_sec = limit_result.reset or limit_result.retry_after
  if limit_result.reset ~= nil then
    headers["RateLimit-Reset"] = tostring(limit_result.reset)
  elseif limit_result.retry_after ~= nil then
    headers["RateLimit-Reset"] = tostring(limit_result.retry_after)
  elseif headers["RateLimit-Limit"] ~= nil then
    headers["RateLimit-Reset"] = "1"
    reset_sec = reset_sec or 1
  end

  if limit_result.retry_after ~= nil then
    headers["Retry-After"] = tostring(limit_result.retry_after)
  end

  -- draft-ietf-httpapi-ratelimit-headers: RateLimit as Structured Field "policy";r=remaining;t=reset_seconds
  local remaining = limit_result.remaining
  if remaining == nil then
    remaining = 0
  end
  if reset_sec == nil then
    reset_sec = 1
  end
  local name = policy_name and tostring(policy_name) or "default"
  name = string.gsub(name, "\\", "\\\\")
  name = string.gsub(name, '"', '\\"')
  headers["RateLimit"] = '"' .. name .. '";r=' .. tostring(remaining) .. ';t=' .. tostring(reset_sec)
end

local function _build_decision(action, reason, extra)
  extra = extra or {}
  local decision = { headers = {} }

  decision.action = action
  decision.reason = reason

  if extra.policy_id then
    decision.policy_id = extra.policy_id
  end

  if extra.rule_name then
    decision.rule_name = extra.rule_name
  end

  if extra.mode then
    decision.mode = extra.mode
  end

  if extra.would_reject ~= nil then
    decision.would_reject = extra.would_reject
  end

  if extra.delay_ms ~= nil then
    decision.delay_ms = extra.delay_ms
  end

  if extra.matched_policy_count ~= nil then
    decision.matched_policy_count = extra.matched_policy_count
  end

  if extra.debug_descriptors ~= nil then
    decision.debug_descriptors = extra.debug_descriptors
  end

  if extra.limit_result then
    decision.limit_result = extra.limit_result
    _apply_limit_headers(decision.headers, extra.limit_result, extra.policy_id)
  end

  if extra.retry_after then
    decision.headers["Retry-After"] = tostring(extra.retry_after)
    if decision.headers["RateLimit-Reset"] == nil then
      decision.headers["RateLimit-Reset"] = tostring(extra.retry_after)
    end
  end

  if action == "reject" then
    decision.headers["X-Fairvisor-Reason"] = reason
    -- Default Retry-After when no limit_result or extra.retry_after provided.
    if decision.headers["Retry-After"] == nil then
      decision.headers["Retry-After"] = "1"
    end
  end

  if type(extra.warning_code) == "string" and extra.warning_code ~= "" then
    decision.headers["X-Fairvisor-Warning"] = extra.warning_code
  end

  return decision
end

local function _wrap_shadow(decision)
  if _shadow_mode and type(_shadow_mode.wrap) == "function" then
    return _shadow_mode.wrap(decision, "shadow")
  end

  decision.mode = "shadow"
  decision.would_reject = decision.action == "reject"
  decision.action = "allow"
  return decision
end

local function _apply_shadow_key(key, is_shadow)
  if not is_shadow or not key then
    return key
  end
  return _call(_shadow_mode.shadow_key, "shadow:" .. tostring(key), key)
end

local function _build_decision_from_loop(loop_result, policy_id)
  local action = "reject"
  if loop_result.allowed == true or loop_result.action == "warn" then
    action = "allow"
  elseif loop_result.action == "throttle" then
    action = "throttle"
  end

  local decision = _build_decision(action, loop_result.reason or "loop_detected", {
    policy_id = policy_id,
    retry_after = loop_result.retry_after,
    delay_ms = loop_result.delay_ms,
    limit_result = loop_result,
    warning_code = loop_result.warning and "loop_warn" or nil,
  })

  if loop_result.loop_count then
    decision.headers["X-Fairvisor-Loop-Count"] = tostring(loop_result.loop_count)
  end

  return decision
end

local function _is_override_active(block, now)
  if type(block) ~= "table" or block.enabled ~= true then
    return false
  end

  local expires_at = block.expires_at
  if type(expires_at) ~= "string" or expires_at == "" then
    return false
  end

  local expires_epoch, parse_err = utils.parse_iso8601(expires_at)
  if parse_err ~= nil then
    return false
  end

  return expires_epoch > now
end

local function _maybe_log_override_state(flags)
  if _last_global_shadow_active ~= flags.global_shadow_active then
    _last_global_shadow_active = flags.global_shadow_active
    _log_warn("evaluate global_shadow_state active=", tostring(flags.global_shadow_active))
  end

  if _last_kill_switch_override_active ~= flags.kill_switch_override_active then
    _last_kill_switch_override_active = flags.kill_switch_override_active
    _log_warn("evaluate kill_switch_override_state active=", tostring(flags.kill_switch_override_active))
  end
end

local function _finalize_decision(decision, start_time, flags, request_context)
  flags = flags or {}
  local latency_us = floor((ngx.now() - start_time) * 1000000)
  decision.latency_us = latency_us
  _inc_metric("fairvisor_decisions_total", 1, {
    action = decision.action,
    reason = decision.reason,
    policy = tostring(decision.policy_id or "none"),
    route = tostring(request_context and request_context.path or ""),
  })
  if flags.global_shadow_active then
    _inc_metric("fairvisor_global_shadow_decisions_total", 1, {
      mode = "runtime_override",
    })
  end
  _set_metric("fairvisor_decision_duration_seconds", {
    route = tostring(request_context and request_context.path or ""),
    mode = tostring(decision.mode or "enforce"),
  }, latency_us / 1000000)
  _set_metric("fairvisor_shadow_mode_active", {
    scope = "request",
  }, decision.mode == "shadow" and 1 or 0)
  _set_metric("fairvisor_kill_switch_active", {
    scope = "request",
  }, decision.reason == "kill_switch" and 1 or 0)
  return decision
end

function _M.init(deps)
  _ensure_dependencies()

  deps = deps or {}
  -- Explicit: use deps.dict when provided, otherwise ngx.shared.fairvisor_counters. evaluate() does not reassign.
  _dict = deps.dict or (ngx and ngx.shared and ngx.shared.fairvisor_counters)
  _health = deps.health

  return true
end

function _M.evaluate(request_context, bundle)
  _ensure_dependencies()

  local now = ngx.now()
  local start_time = now
  local runtime_flags = {
    global_shadow_active = false,
    kill_switch_override_active = false,
  }

  if not bundle then
    return _finalize_decision(_build_decision("reject", "no_bundle_loaded", {}), start_time, runtime_flags, request_context)
  end

  runtime_flags.global_shadow_active = _is_override_active(bundle.global_shadow, now)
  runtime_flags.kill_switch_override_active = _is_override_active(bundle.kill_switch_override, now)
  _set_metric("fairvisor_global_shadow_active", {}, runtime_flags.global_shadow_active and 1 or 0)
  _set_metric("fairvisor_kill_switch_override_active", {}, runtime_flags.kill_switch_override_active and 1 or 0)
  _maybe_log_override_state(runtime_flags)
  if runtime_flags.global_shadow_active or runtime_flags.kill_switch_override_active then
    _log_warn("evaluate runtime_override global_shadow=", tostring(runtime_flags.global_shadow_active),
      " kill_switch_override=", tostring(runtime_flags.kill_switch_override_active),
      " method=", tostring(request_context and request_context.method or ""),
      " path=", tostring(request_context and request_context.path or ""))
  end

  local kill_switches = bundle.kill_switches or {}
  if not runtime_flags.kill_switch_override_active then
    -- Kill-switch descriptors are extracted from request context using scope keys from bundle.
    -- Fallback to precomputed descriptors for tests/harnesses that provide them directly.
    local ks_descriptors = (request_context and (request_context.descriptors or request_context._descriptors)) or {}
    local ks_limit_keys = _collect_kill_switch_scope_keys(kill_switches)
    if #ks_limit_keys > 0 then
      local extracted = _call(_descriptor.extract, nil, ks_limit_keys, request_context)
      if type(extracted) == "table" then
        ks_descriptors = extracted
      end
    end
    local ks_result = _call(
      _kill_switch.check,
      { matched = false },
      kill_switches,
      ks_descriptors,
      request_context and request_context.path,
      now
    )

    if ks_result and ks_result.matched then
      return _finalize_decision(_build_decision("reject", "kill_switch", {
        retry_after = 3600,
        kill_switch = ks_result,
      }), start_time, runtime_flags, request_context)
    end
  else
    _inc_metric("fairvisor_kill_switch_override_skips_total", 1, {})
  end

  local route_index = bundle.route_index
  local matching_policy_ids = {}

  if route_index and type(route_index.match) == "function" then
    matching_policy_ids = route_index:match(
      request_context and request_context.host,
      request_context and request_context.method,
      request_context and request_context.path
    ) or {}
  end
  matching_policy_ids = _dedupe_policy_ids(matching_policy_ids)

  local matched_count = #matching_policy_ids
  _log_debug("evaluate route_match matched=" .. matched_count
    .. " host=" .. tostring(request_context and request_context.host)
    .. " method=" .. tostring(request_context and request_context.method)
    .. " path=" .. tostring(request_context and request_context.path))
  _inc_metric("fairvisor_route_matches_total", 1, {
    matched = matched_count > 0 and "true" or "false",
  })

  if matched_count == 0 then
    return _finalize_decision(_build_decision("allow", "no_matching_policy", {}), start_time, runtime_flags, request_context)
  end

  local last_allow_limit_result = nil
  local last_allow_policy_id = nil
  local last_allow_descriptors = nil
  local pending_non_reject = nil

  if not bundle.policies_by_id then
    _log_warn("evaluate bundle.policies_by_id missing; policy lookup will fail for all matched routes")
    _inc_metric("fairvisor_evaluate_errors_total", 1, { reason = "policies_by_id_missing" })
  end

  for i = 1, #matching_policy_ids do
    local policy_id = matching_policy_ids[i]
    local policy = bundle.policies_by_id and bundle.policies_by_id[policy_id]

    if not policy then
      _log_warn("evaluate policy_id=" .. tostring(policy_id) .. " matched by route_index but not found in policies_by_id")
      _inc_metric("fairvisor_policy_lookup_miss_total", 1, { policy_id = tostring(policy_id) })
    end

    if policy then
      _inc_metric("fairvisor_policy_evaluations_total", 1, {
        policy_id = tostring(policy_id),
      })
      policy.id = policy.id or policy_id
      local is_shadow = runtime_flags.global_shadow_active or _call(_shadow_mode.is_shadow, false, policy)

      local all_limit_keys = _collect_limit_keys(policy)
      local descriptors, missing_keys = _call(_descriptor.extract, {}, all_limit_keys, request_context)
      last_allow_descriptors = descriptors
      missing_keys = missing_keys or {}
      local missing_set = _build_missing_set(missing_keys)

      local found_count = #all_limit_keys - #missing_keys
      _log_debug("evaluate descriptor_extract policy_id=" .. tostring(policy_id)
        .. " keys_total=" .. #all_limit_keys
        .. " keys_found=" .. found_count
        .. " keys_missing=" .. #missing_keys)

      local loop_cfg = policy.spec and policy.spec.loop_detection
      if loop_cfg and loop_cfg.enabled then
        local fingerprint = _call(
          _loop_detector.build_fingerprint,
          "",
          request_context and request_context.method,
          request_context and request_context.path,
          request_context and request_context.query_params,
          request_context and request_context.body_hash,
          descriptors
        )

        local loop_key = _apply_shadow_key(fingerprint, is_shadow) or fingerprint
        local loop_result = _call(_loop_detector.check, { detected = false }, _dict, loop_cfg, loop_key, now)

        if loop_result and loop_result.detected then
          _inc_metric("fairvisor_loop_detected_total", 1, {
            route = tostring(request_context and request_context.path or ""),
          })
          local loop_decision = _build_decision_from_loop(loop_result, policy_id)
          loop_decision.debug_descriptors = descriptors
          loop_decision.matched_policy_count = matched_count
          if is_shadow then
            loop_decision = _wrap_shadow(loop_decision)
          end
          return _finalize_decision(loop_decision, start_time, runtime_flags, request_context)
        end
      end

      local cb_cfg = policy.spec and policy.spec.circuit_breaker
      if cb_cfg and cb_cfg.enabled then
        local cb_key = _build_cb_limit_key(descriptors, policy)
        cb_key = _apply_shadow_key(cb_key, is_shadow) or cb_key

        local request_cost = _resolve_request_cost(policy, request_context)
        local cb_result = _call(_circuit_breaker.check, { tripped = false }, _dict, cb_cfg, cb_key, request_cost, now)
        _set_metric("fairvisor_circuit_state", {
          target = tostring(policy_id),
        }, cb_result and cb_result.state == "open" and 1 or 0)

        if cb_result and cb_result.tripped then
          local decision = _build_decision("reject", "circuit_breaker_open", {
            policy_id = policy_id,
            limit_result = cb_result,
            matched_policy_count = matched_count,
            debug_descriptors = descriptors,
          })
          if is_shadow then
            decision = _wrap_shadow(decision)
          end
          return _finalize_decision(decision, start_time, runtime_flags, request_context)
        end
      end

      local rules = policy.spec and policy.spec.rules or {}
      local matching_rules = _find_matching_rules(rules, request_context, descriptors)

      if #matching_rules == 0 and policy.spec and policy.spec.fallback_limit then
        matching_rules = { policy.spec.fallback_limit }
      end

      for j = 1, #matching_rules do
        local rule = matching_rules[j]
        local rule_limit_keys = rule.limit_keys or {}
        local composite_key = _call(_descriptor.build_composite_key, "", rule_limit_keys, descriptors)
        local rule_missing = _check_missing_keys(rule_limit_keys, missing_set)

        if #rule_missing > 0 then
          _log_missing_descriptors(rule_missing, request_context)
        else
          local counter_key = _build_counter_key(rule, composite_key)
          counter_key = _apply_shadow_key(counter_key, is_shadow) or counter_key

          if type(rule.algorithm_config) == "table" then
            rule.algorithm_config._metric_route = tostring(request_context and request_context.path or "")
            rule.algorithm_config._metric_policy = tostring(policy_id or "")
          end
          local limit_result = _dispatch_limiter(_dict, rule, counter_key, request_context, now)

          local limiter_allowed = (not limit_result) or (limit_result.allowed ~= false)
          _log_debug("evaluate limiter algorithm=" .. tostring(rule.algorithm)
            .. " rule=" .. tostring(rule.name)
            .. " key=" .. tostring(counter_key)
            .. " allowed=" .. tostring(limiter_allowed)
            .. " remaining=" .. tostring(limit_result and limit_result.remaining or ""))
          _inc_metric("fairvisor_limiter_result_total", 1, {
            algorithm = rule.algorithm or "unknown",
            allowed = limiter_allowed and "true" or "false",
          })

          if limit_result then
            last_allow_limit_result = limit_result
            last_allow_policy_id = policy_id
          end

          if limit_result and limit_result.allowed == false then
            local reject_reason = limit_result.reason or ((rule.algorithm or "rule") .. "_exceeded")
            local decision = _build_decision("reject", reject_reason, {
              policy_id = policy_id,
              rule_name = rule.name,
              limit_result = limit_result,
              matched_policy_count = matched_count,
              debug_descriptors = descriptors,
            })

            if is_shadow then
              decision = _wrap_shadow(decision)
            end

            return _finalize_decision(decision, start_time, runtime_flags, request_context)
          end

          if limit_result and limit_result.allowed ~= false then
            if limit_result.remaining ~= nil then
              _set_metric("fairvisor_ratelimit_remaining", {
                window = "request",
                policy = tostring(policy_id or ""),
                route = tostring(request_context and request_context.path or ""),
              }, tonumber(limit_result.remaining) or 0)
            end

            if rule.algorithm == "token_bucket_llm" then
              local estimated_total = tonumber(limit_result.estimated_total or limit_result.reserved or 0) or 0
              if estimated_total > 0 then
                _inc_metric("fairvisor_tokens_consumed_total", estimated_total, {
                  type = "reserved",
                  policy = tostring(policy_id or ""),
                  route = tostring(request_context and request_context.path or ""),
                })
              end
              if limit_result.remaining_tpm ~= nil then
                _set_metric("fairvisor_tokens_remaining", {
                  window = "tpm",
                  policy = tostring(policy_id or ""),
                  route = tostring(request_context and request_context.path or ""),
                }, tonumber(limit_result.remaining_tpm) or 0)
              end
              if limit_result.remaining_tpd ~= nil then
                _set_metric("fairvisor_tokens_remaining", {
                  window = "tpd",
                  policy = tostring(policy_id or ""),
                  route = tostring(request_context and request_context.path or ""),
                }, tonumber(limit_result.remaining_tpd) or 0)
              end
            end

            if limit_result.action == "throttle" then
              pending_non_reject = {
                action = "throttle",
                reason = "budget_throttle",
                policy_id = policy_id,
                rule_name = rule.name,
                delay_ms = limit_result.delay_ms,
                limit_result = limit_result,
                warning_code = "budget_throttle",
                descriptors = descriptors,
              }
            elseif limit_result.action == "warn" and pending_non_reject == nil then
              pending_non_reject = {
                action = "allow",
                reason = "budget_warn",
                policy_id = policy_id,
                rule_name = rule.name,
                limit_result = limit_result,
                warning_code = "budget_warn",
                descriptors = descriptors,
              }
            end
          end
        end
      end
    end
  end

  if pending_non_reject ~= nil then
    local pending = _build_decision(pending_non_reject.action, pending_non_reject.reason, {
      policy_id = pending_non_reject.policy_id,
      rule_name = pending_non_reject.rule_name,
      delay_ms = pending_non_reject.delay_ms,
      limit_result = pending_non_reject.limit_result,
      warning_code = pending_non_reject.warning_code,
      matched_policy_count = matched_count,
      debug_descriptors = pending_non_reject.descriptors,
    })
    return _finalize_decision(pending, start_time, runtime_flags, request_context)
  end

  return _finalize_decision(_build_decision("allow", "all_rules_passed", {
    limit_result = last_allow_limit_result,
    policy_id = last_allow_policy_id,
    matched_policy_count = matched_count,
    debug_descriptors = last_allow_descriptors,
  }), start_time, runtime_flags, request_context)
end

return _M
