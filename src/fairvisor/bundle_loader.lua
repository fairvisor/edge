local type = type
local ipairs = ipairs
local pcall = pcall
local tostring = tostring
local string_find = string.find
local string_gsub = string.gsub
local string_lower = string.lower
local string_match = string.match
local string_sub = string.sub
local descriptor = require("fairvisor.descriptor")
local health = require("fairvisor.health")
local kill_switch = require("fairvisor.kill_switch")
local route_index = require("fairvisor.route_index")
local token_bucket = require("fairvisor.token_bucket")
local cost_budget = require("fairvisor.cost_budget")
local llm_limiter = require("fairvisor.llm_limiter")

local utils = require("fairvisor.utils")
local json_lib = utils.get_json()

local DEFAULT_HOT_RELOAD_INTERVAL = 5

local _current_bundle

local _M = {}

local function _contains_ua_descriptor_key(key)
  if type(key) ~= "string" then
    return false
  end

  local source, _ = descriptor.parse_key(key)
  return source == "ua"
end

local function _collect_descriptor_hints(bundle)
  local hints = {
    needs_user_agent = false,
  }

  if type(bundle) ~= "table" or type(bundle.policies) ~= "table" then
    return hints
  end

  local function consider_key(key)
    if hints.needs_user_agent then
      return
    end

    if _contains_ua_descriptor_key(key) then
      hints.needs_user_agent = true
    end
  end

  for i = 1, #bundle.policies do
    local policy = bundle.policies[i]
    local spec = policy and policy.spec
    local rules = spec and spec.rules or {}
    for j = 1, #rules do
      local rule = rules[j]
      local limit_keys = rule and rule.limit_keys or {}
      for k = 1, #limit_keys do
        consider_key(limit_keys[k])
      end

      local match = rule and rule.match
      if type(match) == "table" then
        for key, _ in pairs(match) do
          consider_key(key)
        end
      end
    end

    local fallback_limit = spec and spec.fallback_limit
    if fallback_limit and type(fallback_limit.limit_keys) == "table" then
      for k = 1, #fallback_limit.limit_keys do
        consider_key(fallback_limit.limit_keys[k])
      end
    end
  end

  local kill_switches = bundle.kill_switches or {}
  for i = 1, #kill_switches do
    consider_key(kill_switches[i] and kill_switches[i].scope_key)
  end

  return hints
end

local function _log_err(...)
  if ngx and ngx.log then ngx.log(ngx.ERR, ...) end
end
local function _log_warn(...)
  if ngx and ngx.log then ngx.log(ngx.WARN, ...) end
end

local function _json_decode(payload)
  if not json_lib then
    return nil, "json_parse_error: no json library"
  end
  local v, err = json_lib.decode(payload)
  if v ~= nil then
    return v, nil
  end
  return nil, err or "json_parse_error"
end

local function _compute_hmac_sha256(signing_key, payload)
  if ngx and ngx.hmac_sha256 then
    return ngx.hmac_sha256(signing_key, payload)
  end

  local ok, hmac = pcall(require, "resty.hmac")
  if ok and hmac and hmac.new then
    local hmac_obj, err = hmac:new(signing_key, hmac.ALGOS and hmac.ALGOS.SHA256)
    if not hmac_obj then
      return nil, "hmac_init_error: " .. tostring(err)
    end

    hmac_obj:update(payload)
    return hmac_obj:final(nil, true)
  end

  if ngx and ngx.hmac_sha1 then
    _log_warn("_compute_hmac_sha256 sha256 unavailable; using sha1 fallback")
    return ngx.hmac_sha1(signing_key, payload)
  end

  return nil, "hmac_sha256_unavailable"
end

local function _encode_signature(raw_signature)
  local enc = utils.encode_base64(raw_signature)
  return enc or raw_signature
end

local function _compute_hash(content)
  if ngx and ngx.sha1_bin then
    local raw = ngx.sha1_bin(content)
    local enc = utils.encode_base64(raw)
    return enc or raw
  end

  if ngx and ngx.md5 then
    return ngx.md5(content)
  end

  return tostring(#content) .. ":" .. string_sub(content, 1, 16)
end

local function _split_signed_bundle(content)
  local line_end = string_find(content, "\n", 1, true)
  if not line_end then
    return nil, nil, "signed_bundle_format_error"
  end

  local signature = string_sub(content, 1, line_end - 1)
  local payload = string_sub(content, line_end + 1)

  if signature == "" or payload == "" then
    return nil, nil, "signed_bundle_format_error"
  end

  return signature, payload
end

local function _read_file(file_path)
  local file = io.open(file_path, "r")
  if not file then
    return nil
  end

  local content = file:read("*a")
  file:close()
  return content
end

local function _validate_rule(policy_id, rule, policy_index, rule_index, errors)
  if type(rule) ~= "table" then
    errors[#errors + 1] = "policy[" .. policy_index .. "] rule[" .. rule_index .. "]: must be a table"
    return nil
  end

  if type(rule.name) ~= "string" or rule.name == "" then
    errors[#errors + 1] = "policy[" .. policy_index .. "] rule[" .. rule_index .. "]: missing name"
    return nil
  end

  local ok, err = descriptor.validate_limit_keys(rule.limit_keys)
  if not ok then
    errors[#errors + 1] = "policy=" .. policy_id .. " rule=" .. rule.name .. " invalid_limit_keys: " .. tostring(err)
    return nil
  end

  local algorithm = rule.algorithm
  local algorithm_config = rule.algorithm_config
  if type(algorithm) ~= "string" or type(algorithm_config) ~= "table" then
    errors[#errors + 1] = "policy=" .. policy_id .. " rule=" .. rule.name .. " invalid_algorithm_definition"
    return nil
  end

  local config_to_validate = {}
  for key, value in pairs(algorithm_config) do
    config_to_validate[key] = value
  end
  config_to_validate.algorithm = algorithm

  if algorithm == "token_bucket" then
    ok, err = token_bucket.validate_config(config_to_validate)
  elseif algorithm == "cost_based" then
    ok, err = cost_budget.validate_config(config_to_validate)
  elseif algorithm == "token_bucket_llm" then
    ok, err = llm_limiter.validate_config(config_to_validate)
  else
    ok = nil
    err = "unsupported algorithm"
  end

  if not ok then
    errors[#errors + 1] = "policy=" .. policy_id .. " rule=" .. rule.name .. " invalid_algorithm_config: " .. tostring(err)
    return nil
  end

  return true
end

local function _normalize_selector_host(host)
  if type(host) ~= "string" then
    return nil
  end

  local trimmed = string_match(host, "^%s*(.-)%s*$")
  if trimmed == nil or trimmed == "" then
    return nil
  end

  local normalized = string_lower(trimmed)
  if string_find(normalized, "://", 1, true) then
    return nil
  end

  if string_find(normalized, "/", 1, true)
      or string_find(normalized, "?", 1, true)
      or string_find(normalized, "#", 1, true)
      or string_find(normalized, "@", 1, true) then
    return nil
  end

  local without_port = string_match(normalized, "^([^:]+):%d+$")
  if without_port ~= nil and without_port ~= "" then
    normalized = without_port
  end

  normalized = string_gsub(normalized, "%.$", "")
  if normalized == "" then
    return nil
  end

  if string_find(normalized, "%.%.", 1, true) then
    return nil
  end

  if not string_match(normalized, "^[a-z0-9][a-z0-9%.%-]*$") then
    return nil
  end

  if string_match(normalized, "[%.%-]$") then
    return nil
  end

  return normalized
end

local function _validate_selector_hosts(policy_id, selector, errors)
  if selector.hosts == nil then
    return true
  end

  if type(selector.hosts) ~= "table" or #selector.hosts == 0 then
    errors[#errors + 1] = "policy=" .. policy_id .. ": selector.hosts must be a non-empty array of hostnames"
    return nil
  end

  local normalized_hosts = {}
  for i = 1, #selector.hosts do
    local normalized_host = _normalize_selector_host(selector.hosts[i])
    if normalized_host == nil then
      errors[#errors + 1] = "policy=" .. policy_id .. ": selector.hosts[" .. i .. "] invalid hostname format"
      return nil
    end
    normalized_hosts[#normalized_hosts + 1] = normalized_host
  end

  selector.hosts = normalized_hosts
  return true
end

local function _validate_policy(policy, policy_index, errors)
  if type(policy) ~= "table" then
    errors[#errors + 1] = "policy[" .. policy_index .. "]: must be a table"
    return nil
  end

  if type(policy.id) ~= "string" or policy.id == "" then
    errors[#errors + 1] = "policy[" .. policy_index .. "]: missing id"
    return nil
  end

  if type(policy.spec) ~= "table" then
    errors[#errors + 1] = "policy=" .. policy.id .. ": missing spec"
    return nil
  end

  if type(policy.spec.selector) ~= "table" then
    errors[#errors + 1] = "policy=" .. policy.id .. ": missing selector"
    return nil
  end

  if not _validate_selector_hosts(policy.id, policy.spec.selector, errors) then
    return nil
  end

  if policy.spec.mode ~= nil and policy.spec.mode ~= "enforce" and policy.spec.mode ~= "shadow" then
    errors[#errors + 1] = "policy=" .. policy.id .. ": invalid mode"
    return nil
  end

  if type(policy.spec.rules) ~= "table" then
    errors[#errors + 1] = "policy=" .. policy.id .. ": rules must be a table"
    return nil
  end

  for rule_index, rule in ipairs(policy.spec.rules) do
    local ok = _validate_rule(policy.id, rule, policy_index, rule_index, errors)
    if not ok then
      return nil
    end
  end

  if policy.spec.fallback_limit ~= nil then
    if type(policy.spec.fallback_limit) ~= "table" then
      errors[#errors + 1] = "policy=" .. policy.id .. ": fallback_limit must be a table"
      return nil
    end
    local fl = policy.spec.fallback_limit
    local rule_for_validate = (type(fl.name) == "string" and fl.name ~= "") and fl
      or setmetatable({ name = "fallback_limit" }, { __index = fl })
    local ok = _validate_rule(policy.id, rule_for_validate, policy_index, "fallback_limit", errors)
    if not ok then
      return nil
    end
  end

  return true
end

local function _validate_top_level(bundle)
  if type(bundle) ~= "table" then
    return nil, "bundle must be a table"
  end

  if type(bundle.bundle_version) ~= "number" or bundle.bundle_version <= 0 then
    return nil, "bundle_version must be a positive number"
  end

  if type(bundle.policies) ~= "table" then
    return nil, "policies must be a table"
  end

  if bundle.issued_at ~= nil then
    local _, issued_err = utils.parse_iso8601(bundle.issued_at)
    if issued_err then
      return nil, "issued_at_invalid"
    end
  end

  if bundle.expires_at ~= nil then
    local expires_epoch, expires_err = utils.parse_iso8601(bundle.expires_at)
    if expires_err then
      return nil, "expires_at_invalid"
    end

    if ngx and ngx.now and expires_epoch <= ngx.now() then
      return nil, "bundle_expired"
    end
  end

  if bundle.kill_switches ~= nil then
    local ok, err = kill_switch.validate(bundle.kill_switches)
    if not ok then
      return nil, "kill_switch_invalid: " .. tostring(err)
    end
  end

  local function _validate_runtime_override(field_name)
    local block = bundle[field_name]
    if block == nil then
      return true
    end

    if type(block) ~= "table" then
      return nil, field_name .. "_invalid: must be a table"
    end

    if block.enabled == nil then
      return nil, field_name .. "_invalid: enabled is required"
    end

    if type(block.enabled) ~= "boolean" then
      return nil, field_name .. "_invalid: enabled must be a boolean"
    end

    if block.enabled ~= true then
      return true
    end

    if type(block.reason) ~= "string" or block.reason == "" then
      return nil, field_name .. "_invalid: reason is required when enabled"
    end

    if #block.reason > 256 then
      return nil, field_name .. "_invalid: reason must be <= 256 chars"
    end

    if type(block.expires_at) ~= "string" or block.expires_at == "" then
      return nil, field_name .. "_invalid: expires_at is required when enabled"
    end

    local expires_epoch, expires_err = utils.parse_iso8601(block.expires_at)
    if expires_err then
      return nil, field_name .. "_invalid: expires_at_invalid"
    end

    if ngx and ngx.now and expires_epoch <= ngx.now() then
      return nil, field_name .. "_invalid: expired"
    end

    return true
  end

  local shadow_ok, shadow_err = _validate_runtime_override("global_shadow")
  if not shadow_ok then
    return nil, shadow_err
  end

  local ks_override_ok, ks_override_err = _validate_runtime_override("kill_switch_override")
  if not ks_override_ok then
    return nil, ks_override_err
  end

  return true
end

--- Validate a raw bundle table (e.g. from json.decode). Does not apply or load.
-- @param bundle (table) decoded bundle with bundle_version, policies, optional issued_at, expires_at, kill_switches
-- @return table array of error strings; empty table if valid
function _M.validate_bundle(bundle)
  local errors = {}

  local ok, err = _validate_top_level(bundle)
  if not ok then
    errors[#errors + 1] = err
    return errors
  end

  for policy_index, policy in ipairs(bundle.policies) do
    _validate_policy(policy, policy_index, errors)
  end

  return errors
end

--- Validate a raw bundle table and return cli-friendly status tuple.
-- @param bundle (table) decoded bundle
-- @return true|nil true when valid, nil when errors are present
-- @return table|nil array of errors when invalid
function _M.validate(bundle)
  local errors = _M.validate_bundle(bundle)
  if #errors > 0 then
    return nil, errors
  end
  return true, nil
end

--- Load and compile a bundle from a JSON string. Optionally verify HMAC signature and enforce monotonic version.
-- @param json_string (string) JSON payload, or "signature\npayload" when signing_key is set
-- @param signing_key (string|nil) if set, first line is base64 HMAC-SHA256 signature, rest is payload
-- @param current_version (number|nil) if set, bundle_version must be > current_version
-- @return table|nil compiled bundle (version, hash, policies, route_index, kill_switches, loaded_at, ...) or nil
-- @return string|nil error message when first return is nil
function _M.load_from_string(json_string, signing_key, current_version)
  if type(json_string) ~= "string" or json_string == "" then
    return nil, "json_string_required"
  end

  local payload = json_string
  if signing_key then
    local signature, split_payload, split_err = _split_signed_bundle(json_string)
    if not signature then
      return nil, split_err
    end

    local expected_raw, hmac_err = _compute_hmac_sha256(signing_key, split_payload)
    if not expected_raw then
      return nil, hmac_err
    end

    local expected_signature = _encode_signature(expected_raw)
    if not utils.constant_time_equals(expected_signature, signature) then
      return nil, "invalid_signature"
    end

    payload = split_payload
  end

  local bundle, decode_err = _json_decode(payload)
  if not bundle then
    return nil, decode_err
  end

  local top_ok, top_err = _validate_top_level(bundle)
  if not top_ok then
    return nil, top_err
  end

  if current_version ~= nil and bundle.bundle_version <= current_version then
    return nil, "version_not_monotonic"
  end

  local valid_policies = {}
  local validation_errors = {}
  for policy_index, policy in ipairs(bundle.policies) do
    if _validate_policy(policy, policy_index, validation_errors) then
      valid_policies[#valid_policies + 1] = policy
    end
  end

  if #validation_errors > 0 then
    for _, validation_error in ipairs(validation_errors) do
      _log_err("load_from_string validation_error=" .. validation_error)
    end
  end

  local route_idx, route_err = route_index.build(valid_policies)
  if not route_idx then
    return nil, "route_index_build_error: " .. tostring(route_err)
  end

  local policies_by_id = {}
  for i = 1, #valid_policies do
    local p = valid_policies[i]
    policies_by_id[p.id] = p
  end

  local now_value = ngx and ngx.now and ngx.now() or 0
  local hash = _compute_hash(payload)

  return {
    version = bundle.bundle_version,
    hash = hash,
    policies = valid_policies,
    policies_by_id = policies_by_id,
    kill_switches = bundle.kill_switches or {},
    global_shadow = bundle.global_shadow,
    kill_switch_override = bundle.kill_switch_override,
    route_index = route_idx,
    defaults = bundle.defaults or {},
    descriptor_hints = _collect_descriptor_hints(bundle),
    loaded_at = now_value,
    validation_errors = validation_errors,
  }
end

--- Load and compile a bundle from a file. Reads file content then delegates to load_from_string.
-- @param file_path (string) path to JSON bundle file
-- @param signing_key (string|nil) same as load_from_string
-- @param current_version (number|nil) same as load_from_string
-- @return table|nil compiled bundle or nil
-- @return string|nil error message when first return is nil (e.g. file_not_found)
function _M.load_from_file(file_path, signing_key, current_version)
  if type(file_path) ~= "string" or file_path == "" then
    return nil, "file_path_required"
  end

  local content = _read_file(file_path)
  if not content then
    return nil, "file_not_found"
  end

  return _M.load_from_string(content, signing_key, current_version)
end

--- Apply a compiled bundle as the active bundle and update health state.
-- @param compiled (table) result from load_from_string or load_from_file
-- @return true|nil success or nil
-- @return string|nil error message when first return is nil (e.g. compiled_bundle_required)
function _M.apply(compiled)
  if type(compiled) ~= "table" then
    return nil, "compiled_bundle_required"
  end

  _current_bundle = compiled
  health.set_bundle_state(compiled.version, compiled.hash, compiled.loaded_at)

  return true
end

--- Return the currently active compiled bundle, or nil if none applied.
-- @return table|nil current bundle (version, hash, policies, route_index, ...) or nil
function _M.get_current()
  return _current_bundle
end

--- Start a periodic timer that reloads the bundle from a file and applies it if version is monotonic.
-- @param interval (number|nil) seconds between reloads; default DEFAULT_HOT_RELOAD_INTERVAL
-- @param file_path (string) path to JSON bundle file
-- @param signing_key (string|nil) optional; same as load_from_file
-- @return true|nil success or nil
-- @return string|nil error message when first return is nil (e.g. ngx_timer_unavailable)
function _M.init_hot_reload(interval, file_path, signing_key)
  local effective_interval = interval or DEFAULT_HOT_RELOAD_INTERVAL

  if not (ngx and ngx.timer and ngx.timer.every) then
    return nil, "ngx_timer_unavailable"
  end

  local ok, err = ngx.timer.every(effective_interval, function()
    local current = _M.get_current()
    local current_version = current and current.version or nil

    local compiled, load_err = _M.load_from_file(file_path, signing_key, current_version)
    if compiled then
      _M.apply(compiled)
      return
    end

    if load_err ~= "version_not_monotonic" and load_err ~= "file_not_found" then
      _log_err("init_hot_reload hot_reload_failed: " .. tostring(load_err))
    elseif load_err == "file_not_found" then
      _log_warn("init_hot_reload hot_reload_file_not_found")
    end
  end)

  if not ok then
    return nil, "hot_reload_init_failed: " .. tostring(err)
  end

  return true
end

return _M
