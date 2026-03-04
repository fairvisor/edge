package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local runner = gherkin.new({ describe = describe, context = context, it = it })
local _managed_modules = {
  "fairvisor.descriptor",
  "fairvisor.token_bucket",
  "fairvisor.cost_budget",
  "fairvisor.loop_detector",
  "fairvisor.circuit_breaker",
  "fairvisor.kill_switch",
  "fairvisor.shadow_mode",
  "fairvisor.llm_limiter",
}
local _original_preload = {}

for i = 1, #_managed_modules do
  local name = _managed_modules[i]
  _original_preload[name] = package.preload[name]
end

after_each(function()
  package.loaded["fairvisor.rule_engine"] = nil
  for i = 1, #_managed_modules do
    local name = _managed_modules[i]
    package.loaded[name] = nil
    package.preload[name] = _original_preload[name]
  end
end)

local function _contains(list, value)
  for i = 1, #list do
    if list[i] == value then
      return true
    end
  end
  return false
end

local function _new_policy(id, mode, rules, fallback_limit)
  return {
    id = id,
    spec = {
      mode = mode,
      rules = rules or {},
      fallback_limit = fallback_limit,
    },
  }
end

local function _setup_engine(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.dict = env.dict
  ctx.time = env.time
  ctx.calls = {}
  ctx.logs = {}
  ctx.metrics = {}
  ctx.rule_results = {}
  ctx.kill_switch_matched = false
  ctx.loop_detected = false
  ctx.loop_action = "reject"
  ctx.circuit_tripped = false

  ngx.log = function(_level, ...)
    ctx.logs[#ctx.logs + 1] = table.concat({ ... })
  end

  ctx.request_context = {
    method = "GET",
    path = "/v1/chat",
    headers = {},
    query_params = {},
    jwt_claims = {},
    _descriptors = {},
  }

  ctx.matching_policy_ids = {}
  ctx.bundle = {
    kill_switches = {},
    route_index = {
      match = function(_self, host, method, path)
        ctx.calls[#ctx.calls + 1] = "route_match"
        ctx.route_match_args = {
          host = host,
          method = method,
          path = path,
        }
        return ctx.matching_policy_ids
      end,
    },
    policies_by_id = {},
  }

  local descriptor = {
    extract = function(limit_keys, request_context)
      ctx.calls[#ctx.calls + 1] = "descriptor_extract"
      local descriptors = {}
      local missing = {}

      for i = 1, #limit_keys do
        local key = limit_keys[i]
        if request_context._descriptors[key] ~= nil then
          descriptors[key] = tostring(request_context._descriptors[key])
        else
          missing[#missing + 1] = key
        end
      end

      return descriptors, missing
    end,
    build_composite_key = function(limit_keys, descriptors)
      local parts = {}
      for i = 1, #limit_keys do
        local key = limit_keys[i]
        parts[#parts + 1] = tostring(descriptors[key] or "")
      end
      return table.concat(parts, ":")
    end,
    parse_key = function(key)
      local sep = string.find(key, ":", 1, true)
      if not sep then
        return nil, nil
      end
      return string.sub(key, 1, sep - 1), string.sub(key, sep + 1)
    end,
  }

  local token_bucket = {
    build_key = function(rule_name, limit_key)
      return "tb:" .. rule_name .. ":" .. tostring(limit_key or "")
    end,
    resolve_cost = function(_config, _request_context)
      return 1
    end,
    check = function(_dict, key, _config, _cost)
      local normalized_key = string.gsub(key, "^shadow:", "")
      local rule_name = string.match(normalized_key, "^tb:([^:]+):") or ""
      ctx.calls[#ctx.calls + 1] = "tb_check:" .. rule_name
      return ctx.rule_results[rule_name] or {
        allowed = true,
        limit = 200,
        remaining = 50,
        reset = 1,
      }
    end,
  }

  local cost_budget = {
    build_key = function(rule_name, limit_key)
      return "cb:" .. rule_name .. ":" .. tostring(limit_key or "")
    end,
    resolve_cost = function(_config, _request_context)
      return 1
    end,
    check = function(_dict, key, _config, _cost, _now)
      local rule_name = string.match(key, "^cb:([^:]+):") or ""
      ctx.calls[#ctx.calls + 1] = "cbudget_check:" .. rule_name
      return ctx.rule_results[rule_name] or { allowed = true }
    end,
  }

  local loop_detector = {
    build_fingerprint = function(_method, _path, _query, _body_hash, _descriptors)
      return "fp"
    end,
    check = function(_dict, _config, _key, _now)
      ctx.calls[#ctx.calls + 1] = "loop_check"
      if ctx.loop_detected then
        local loop_action = ctx.loop_action or "reject"
        local delay_ms = nil
        local retry_after = 60
        local allowed = false
        if loop_action == "warn" then
          allowed = true
          retry_after = nil
        elseif loop_action == "throttle" then
          retry_after = nil
          delay_ms = 900
        end
        return {
          detected = true,
          allowed = allowed,
          action = loop_action,
          reason = "loop_detected",
          retry_after = retry_after,
          delay_ms = delay_ms,
          loop_count = 10,
        }
      end
      return { detected = false }
    end,
  }

  local circuit_breaker = {
    check = function(_dict, _config, _key, _cost, _now)
      ctx.calls[#ctx.calls + 1] = "circuit_check"
      if ctx.circuit_tripped then
        return { tripped = true, retry_after = 30 }
      end
      return { tripped = false }
    end,
  }

  local kill_switch = {
    check = function(_kill_switches, _descriptors, _path, _now)
      ctx.calls[#ctx.calls + 1] = "kill_switch_check"
      if ctx.kill_switch_matched then
        return { matched = true }
      end
      return { matched = false }
    end,
  }

  local shadow_mode = {
    is_shadow = function(policy)
      return policy and policy.spec and policy.spec.mode == "shadow" or false
    end,
    wrap = function(decision, mode)
      decision.mode = mode or "shadow"
      decision.would_reject = decision.action == "reject"
      decision.action = "allow"
      return decision
    end,
    shadow_key = function(key)
      return "shadow:" .. key
    end,
  }

  local llm_limiter = {
    check = function(_dict, _key, _config, _request_context, _now)
      ctx.calls[#ctx.calls + 1] = "llm_check"
      return { allowed = true }
    end,
  }

  local health = {
    inc = function(_self, name, labels, value)
      ctx.metrics[#ctx.metrics + 1] = {
        kind = "inc",
        name = name,
        value = value,
        labels = labels,
      }
    end,
    set = function(_self, name, labels, value)
      ctx.metrics[#ctx.metrics + 1] = {
        kind = "set",
        name = name,
        value = value,
        labels = labels,
      }
    end,
  }

  package.loaded["fairvisor.rule_engine"] = nil
  package.loaded["fairvisor.descriptor"] = nil
  package.loaded["fairvisor.token_bucket"] = nil
  package.loaded["fairvisor.cost_budget"] = nil
  package.loaded["fairvisor.loop_detector"] = nil
  package.loaded["fairvisor.circuit_breaker"] = nil
  package.loaded["fairvisor.kill_switch"] = nil
  package.loaded["fairvisor.shadow_mode"] = nil
  package.loaded["fairvisor.llm_limiter"] = nil

  package.preload["fairvisor.descriptor"] = function() return descriptor end
  package.preload["fairvisor.token_bucket"] = function() return token_bucket end
  package.preload["fairvisor.cost_budget"] = function() return cost_budget end
  package.preload["fairvisor.loop_detector"] = function() return loop_detector end
  package.preload["fairvisor.circuit_breaker"] = function() return circuit_breaker end
  package.preload["fairvisor.kill_switch"] = function() return kill_switch end
  package.preload["fairvisor.shadow_mode"] = function() return shadow_mode end
  package.preload["fairvisor.llm_limiter"] = function() return llm_limiter end

  ctx.engine = require("fairvisor.rule_engine")
  ctx.engine.init({ dict = ctx.dict, health = health })
end

runner:given("^the rule engine test environment is reset$", function(ctx)
  _setup_engine(ctx)
end)

runner:given("^fixture AC%-1 all must pass with second policy rejection$", function(ctx)
  ctx.request_context._descriptors["jwt:org_id"] = "org-1"
  ctx.matching_policy_ids = { "p1", "p2" }
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "p1_rule",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      algorithm_config = {},
    },
  })
  ctx.bundle.policies_by_id.p2 = _new_policy("p2", "enforce", {
    {
      name = "p2_rule",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      algorithm_config = {},
    },
  })
  ctx.rule_results.p1_rule = { allowed = true, limit = 200, remaining = 100, reset = 1 }
  ctx.rule_results.p2_rule = { allowed = false, reason = "rate_limited", limit = 200, remaining = 0, retry_after = 1 }
end)

runner:given("^fixture AC%-2 claim mismatch skips rule$", function(ctx)
  ctx.matching_policy_ids = { "p1" }
  ctx.request_context.jwt_claims.plan = "free"
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "pro_only",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      match = { ["jwt:plan"] = "pro" },
      algorithm_config = {},
    },
  })
end)

runner:given("^fixture AC%-3 fallback limit applies$", function(ctx)
  ctx.matching_policy_ids = { "p1" }
  ctx.request_context.jwt_claims.plan = "free"
  ctx.request_context._descriptors["jwt:org_id"] = "org-9"
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "pro_only",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      match = { ["jwt:plan"] = "pro" },
      algorithm_config = {},
    },
  }, {
    name = "fallback_rule",
    algorithm = "token_bucket",
    limit_keys = { "jwt:org_id" },
    algorithm_config = {},
  })
  ctx.rule_results.fallback_rule = { allowed = true, limit = 100, remaining = 20, reset = 1 }
end)

runner:given("^fixture AC%-4 no matching rules and no fallback$", function(ctx)
  ctx.matching_policy_ids = { "p1" }
  ctx.request_context.jwt_claims.plan = "free"
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "pro_only",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      match = { ["jwt:plan"] = "pro" },
      algorithm_config = {},
    },
  })
end)

runner:given("^fixture AC%-5 kill switch matches$", function(ctx)
  ctx.kill_switch_matched = true
  ctx.matching_policy_ids = { "p1" }
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "any_rule",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      algorithm_config = {},
    },
  })
end)

runner:given("^fixture AC%-6 loop detection triggers before circuit and rules$", function(ctx)
  ctx.matching_policy_ids = { "p1" }
  ctx.loop_detected = true
  ctx.loop_action = "reject"
  ctx.request_context._descriptors["jwt:org_id"] = "org-1"
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "rule1",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      algorithm_config = {},
    },
  })
  ctx.bundle.policies_by_id.p1.spec.loop_detection = { enabled = true }
  ctx.bundle.policies_by_id.p1.spec.circuit_breaker = { enabled = true }
end)

runner:given("^fixture loop detection throttles instead of rejecting$", function(ctx)
  ctx.matching_policy_ids = { "p1" }
  ctx.loop_detected = true
  ctx.loop_action = "throttle"
  ctx.request_context._descriptors["jwt:org_id"] = "org-1"
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "rule1",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      algorithm_config = {},
    },
  })
  ctx.bundle.policies_by_id.p1.spec.loop_detection = { enabled = true, action = "throttle" }
end)

runner:given("^fixture AC%-7 shadow mode wraps reject as allow$", function(ctx)
  ctx.matching_policy_ids = { "p1" }
  ctx.request_context._descriptors["jwt:org_id"] = "org-shadow"
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "shadow", {
    {
      name = "shadow_rule",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      algorithm_config = {},
    },
  })
  ctx.rule_results.shadow_rule = { allowed = false, reason = "rate_limited", limit = 100, remaining = 0, retry_after = 1 }
end)

runner:given("^fixture AC%-8 missing descriptor is fail%-open$", function(ctx)
  ctx.matching_policy_ids = { "p1" }
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "needs_org",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      algorithm_config = {},
    },
  })
end)

runner:given("^fixture AC%-9 allow includes rate headers$", function(ctx)
  ctx.matching_policy_ids = { "p1" }
  ctx.request_context._descriptors["jwt:org_id"] = "org-allow"
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "allow_rule",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      algorithm_config = {},
    },
  })
  ctx.rule_results.allow_rule = {
    allowed = true,
    limit = 200,
    remaining = 50,
    reset = 1,
  }
end)

runner:given("^fixture AC%-10 reject includes reason and retry headers$", function(ctx)
  ctx.matching_policy_ids = { "p1" }
  ctx.request_context._descriptors["jwt:org_id"] = "org-reject"
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "reject_rule",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      algorithm_config = {},
    },
  })
  ctx.rule_results.reject_rule = {
    allowed = false,
    reason = "rate_limited",
    limit = 200,
    remaining = 0,
    retry_after = 3,
  }
end)

runner:given("^fixture bundle missing policies_by_id with matching route$", function(ctx)
  ctx.matching_policy_ids = { "missing-map-policy" }
  ctx.request_context._descriptors["jwt:org_id"] = "org-1"
  ctx.bundle.policies_by_id = nil
end)

runner:given("^fixture route returns policy_id not in policies_by_id$", function(ctx)
  ctx.matching_policy_ids = { "ghost-policy" }
  ctx.request_context._descriptors["jwt:org_id"] = "org-1"
  ctx.bundle.policies_by_id = {}
  ctx.bundle.policies_by_id.other = _new_policy("other", "enforce", {})
end)

runner:given("^fixture duplicate route matches evaluate each policy once$", function(ctx)
  ctx.matching_policy_ids = { "p1", "p1" }
  ctx.request_context._descriptors["jwt:org_id"] = "org-dedupe"
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "dedupe_rule",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      algorithm_config = {},
    },
  })
  ctx.rule_results.dedupe_rule = { allowed = true, limit = 20, remaining = 19, reset = 1 }
end)

runner:given("^fixture route matching receives normalized host context$", function(ctx)
  ctx.request_context.host = "api.example.com"
  ctx.request_context.method = "GET"
  ctx.request_context.path = "/v1/chat"
  ctx.matching_policy_ids = {}
end)

runner:given("^fixture global shadow override forces allow with headers$", function(ctx)
  ctx.matching_policy_ids = { "p1" }
  ctx.request_context._descriptors["jwt:org_id"] = "org-shadow-global"
  ctx.bundle.global_shadow = {
    enabled = true,
    reason = "incident-global-shadow",
    expires_at = "2030-01-01T00:00:00Z",
  }
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "reject_rule",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      algorithm_config = {},
    },
  })
  ctx.rule_results.reject_rule = {
    allowed = false,
    reason = "rate_limited",
    limit = 100,
    remaining = 0,
    retry_after = 2,
  }
end)

runner:given("^fixture kill switch override skips kill switch$", function(ctx)
  ctx.kill_switch_matched = true
  ctx.matching_policy_ids = { "p1" }
  ctx.request_context._descriptors["jwt:org_id"] = "org-ks-override"
  ctx.bundle.kill_switch_override = {
    enabled = true,
    reason = "incident-ks-override",
    expires_at = "2030-01-01T00:00:00Z",
  }
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "allow_rule",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
      algorithm_config = {},
    },
  })
  ctx.rule_results.allow_rule = { allowed = true, limit = 100, remaining = 90, reset = 1 }
end)

runner:when("^I evaluate the request$", function(ctx)
  ctx.decision = ctx.engine.evaluate(ctx.request_context, ctx.bundle)
end)

runner:then_("^decision action is \"([^\"]+)\"$", function(ctx, action)
  assert.equals(action, ctx.decision.action)
end)

runner:then_("^decision reason is \"([^\"]+)\"$", function(ctx, reason)
  assert.equals(reason, ctx.decision.reason)
end)

runner:then_("^decision policy_id is \"([^\"]+)\"$", function(ctx, policy_id)
  assert.equals(policy_id, ctx.decision.policy_id)
end)

runner:then_("^decision rule_name is \"([^\"]+)\"$", function(ctx, rule_name)
  assert.equals(rule_name, ctx.decision.rule_name)
end)

runner:then_("^token bucket check was called for \"([^\"]+)\"$", function(ctx, rule_name)
  assert.is_true(_contains(ctx.calls, "tb_check:" .. rule_name))
end)

runner:then_("^token bucket check was called (%d+) time for \"([^\"]+)\"$", function(ctx, expected_count, rule_name)
  local actual_count = 0
  for i = 1, #ctx.calls do
    if ctx.calls[i] == "tb_check:" .. rule_name then
      actual_count = actual_count + 1
    end
  end
  assert.equals(tonumber(expected_count), actual_count)
end)

runner:then_("^token bucket check was not called$", function(ctx)
  for i = 1, #ctx.calls do
    assert.is_nil(string.match(ctx.calls[i], "^tb_check:"))
  end
end)

runner:then_("^kill switch ran before route matching$", function(ctx)
  local kill_switch_index = nil
  local route_match_index = nil

  for i = 1, #ctx.calls do
    if ctx.calls[i] == "kill_switch_check" and kill_switch_index == nil then
      kill_switch_index = i
    end
    if ctx.calls[i] == "route_match" and route_match_index == nil then
      route_match_index = i
    end
  end

  assert.is_not_nil(kill_switch_index)
  assert.is_not_nil(route_match_index)
  assert.is_true(kill_switch_index < route_match_index)
end)

runner:then_("^route matching did not run$", function(ctx)
  assert.is_false(_contains(ctx.calls, "route_match"))
end)

runner:then_("^loop check ran before circuit and limiter checks$", function(ctx)
  local loop_index = nil
  local circuit_index = nil
  local tb_index = nil

  for i = 1, #ctx.calls do
    local call = ctx.calls[i]
    if call == "loop_check" then loop_index = i end
    if call == "circuit_check" then circuit_index = i end
    if string.match(call, "^tb_check:") then tb_index = i end
  end

  assert.is_not_nil(loop_index)
  assert.is_nil(circuit_index)
  assert.is_nil(tb_index)
end)

runner:then_("^loop throttle decision includes delay_ms (%d+)$", function(ctx, delay_ms)
  assert.equals("throttle", ctx.decision.action)
  assert.equals(tonumber(delay_ms), ctx.decision.delay_ms)
end)

runner:then_("^decision is shadow allow with would_reject true$", function(ctx)
  assert.equals("allow", ctx.decision.action)
  assert.equals("shadow", ctx.decision.mode)
  assert.is_true(ctx.decision.would_reject)
end)

runner:then_("^missing descriptor was logged and metered$", function(ctx)
  local found_log = false
  for i = 1, #ctx.logs do
    if string.find(ctx.logs[i], "descriptor_missing", 1, true) then
      found_log = true
      break
    end
  end
  assert.is_true(found_log)

  local found_metric = false
  for i = 1, #ctx.metrics do
    if ctx.metrics[i].name == "fairvisor_descriptor_missing_total" then
      found_metric = true
      break
    end
  end
  assert.is_true(found_metric)
end)

runner:then_("^allow decision includes RateLimit headers$", function(ctx)
  assert.equals("200", ctx.decision.headers["RateLimit-Limit"])
  assert.equals("50", ctx.decision.headers["RateLimit-Remaining"])
  assert.equals("1", ctx.decision.headers["RateLimit-Reset"])
  assert.is_string(ctx.decision.headers["RateLimit"])
  assert.is_true(ctx.decision.headers["RateLimit"]:find('"p1";r=50;t=1') ~= nil,
    "RateLimit (structured) should contain policy p1, r=50, t=1")
end)

runner:then_("^reject decision includes fairvisor reason and retry headers$", function(ctx)
  assert.equals("rate_limited", ctx.decision.headers["X-Fairvisor-Reason"])
  assert.equals("3", ctx.decision.headers["Retry-After"])
  assert.equals("200", ctx.decision.headers["RateLimit-Limit"])
  assert.equals("0", ctx.decision.headers["RateLimit-Remaining"])
  assert.equals("3", ctx.decision.headers["RateLimit-Reset"])
  assert.is_string(ctx.decision.headers["RateLimit"])
  assert.is_true(ctx.decision.headers["RateLimit"]:find('"p1";r=0;t=3') ~= nil,
    "RateLimit (structured) should contain policy p1, r=0, t=3")
end)

runner:then_("^policies_by_id missing was logged and metered$", function(ctx)
  local found_log = false
  for i = 1, #ctx.logs do
    if string.find(ctx.logs[i], "policies_by_id missing", 1, true) or string.find(ctx.logs[i], "policies_by_id_missing", 1, true) then
      found_log = true
      break
    end
  end
  assert.is_true(found_log)
  local found_metric = false
  for i = 1, #ctx.metrics do
    local m = ctx.metrics[i]
    if m.name == "fairvisor_evaluate_errors_total" and m.labels and m.labels.reason == "policies_by_id_missing" then
      found_metric = true
      break
    end
  end
  assert.is_true(found_metric)
end)

runner:then_("^policy evaluation metric count for \"([^\"]+)\" is (%d+)$", function(ctx, policy_id, expected_count)
  local total = 0
  for i = 1, #ctx.metrics do
    local metric = ctx.metrics[i]
    if metric.name == "fairvisor_policy_evaluations_total"
        and metric.labels
        and metric.labels.policy_id == policy_id then
      total = total + (metric.value or 1)
    end
  end
  assert.equals(tonumber(expected_count), total)
end)

runner:then_("^policy not found in policies_by_id was logged$", function(ctx)
  local found = false
  for i = 1, #ctx.logs do
    if string.find(ctx.logs[i], "not found in policies_by_id", 1, true) then
      found = true
      break
    end
  end
  assert.is_true(found)
end)

runner:then_("^decision does not expose override headers$", function(ctx)
  assert.is_nil(ctx.decision.headers["X-Fairvisor-Global-Shadow"])
  assert.is_nil(ctx.decision.headers["X-Fairvisor-Global-Shadow-Reason"])
  assert.is_nil(ctx.decision.headers["X-Fairvisor-Global-Shadow-Expires-At"])
  assert.is_nil(ctx.decision.headers["X-Fairvisor-Kill-Switch-Override"])
  assert.is_nil(ctx.decision.headers["X-Fairvisor-Kill-Switch-Override-Reason"])
  assert.is_nil(ctx.decision.headers["X-Fairvisor-Kill-Switch-Override-Expires-At"])
end)

runner:then_("^kill switch check was skipped$", function(ctx)
  assert.is_false(_contains(ctx.calls, "kill_switch_check"))

  local skip_metric = false
  for i = 1, #ctx.metrics do
    local metric = ctx.metrics[i]
    if metric.name == "fairvisor_kill_switch_override_skips_total" then
      skip_metric = true
      break
    end
  end
  assert.is_true(skip_metric)
end)

runner:then_("^global shadow metrics are emitted$", function(ctx)
  local shadow_active = false
  local shadow_decisions = false

  for i = 1, #ctx.metrics do
    local metric = ctx.metrics[i]
    if metric.name == "fairvisor_global_shadow_active" and metric.kind == "set" and metric.value == 1 then
      shadow_active = true
    end
    if metric.name == "fairvisor_global_shadow_decisions_total" and metric.kind == "inc" then
      shadow_decisions = true
    end
  end

  assert.is_true(shadow_active)
  assert.is_true(shadow_decisions)
end)

runner:then_('^route matching received host "([^"]+)" method "([^"]+)" and path "([^"]+)"$', function(ctx, host, method, path)
  assert.is_table(ctx.route_match_args)
  assert.equals(host, ctx.route_match_args.host)
  assert.equals(method, ctx.route_match_args.method)
  assert.equals(path, ctx.route_match_args.path)
end)

runner:feature_file_relative("features/rule_engine.feature")
