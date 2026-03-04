-- Token-based LLM rate limiting (013): TPM/TPD buckets, pessimistic reservation,
-- reconciliation, prompt estimation (simple_word or header_hint).
-- Public API: validate_config, check, reconcile, estimate_prompt_tokens, build_error_response.

local ceil = math.ceil
local floor = math.floor
local min = math.min
local max = math.max
local tonumber = tonumber
local tostring = tostring
local type = type
local string_find = string.find
local string_gsub = string.gsub
local string_format = string.format
local string_lower = string.lower
local string_sub = string.sub
local os_date = os.date

local token_bucket = require("fairvisor.token_bucket")

-- shared_dict key format: tpm:{limit_key}, tpd:{limit_key}:{YYYYMMDD}
local TPM_KEY_PREFIX = "tpm:"
local TPD_KEY_PREFIX = "tpd:"

local utils = require("fairvisor.utils")
local json_lib = utils.get_json()

local VALID_ESTIMATORS = {
  simple_word = true,
  header_hint = true,
}

local RESULT_FIELDS = {
  "allowed",
  "reason",
  "prompt_tokens",
  "max_prompt_tokens",
  "estimated_total",
  "max_tokens_per_request",
  "remaining_tokens",
  "limit_tokens",
  "retry_after",
  "reserved",
  "remaining_tpm",
  "remaining_tpd",
  "limit_tpm",
  "limit_tpd",
}

local _result = {}
local _reconcile_result = {}

local _M = {}
local _health_module = nil

local function _log_warn(...)
  if ngx and ngx.log then ngx.log(ngx.WARN, ...) end
end

local function _encode_json(value)
  if not json_lib or not json_lib.encode then
    return nil
  end
  local out, _ = json_lib.encode(value)
  return out
end

local function _clear_result()
  for i = 1, #RESULT_FIELDS do
    _result[RESULT_FIELDS[i]] = nil
  end
end

local function _set_reject(reason)
  _clear_result()
  _result.allowed = false
  _result.reason = reason
  return _result
end

local function _validation_error(msg)
  return nil, msg
end

local function _get_health_module()
  if _health_module ~= nil then
    return _health_module
  end
  local ok, mod = pcall(require, "fairvisor.health")
  if ok and mod then
    _health_module = mod
  else
    _health_module = false
  end
  return _health_module
end

local function _inc_metric(name, labels, value)
  local health = _get_health_module()
  if not health or health == false or type(health.inc) ~= "function" then
    return
  end
  pcall(health.inc, health, name, labels or {}, value)
end

local function _set_metric(name, labels, value)
  local health = _get_health_module()
  if not health or health == false or type(health.set) ~= "function" then
    return
  end
  pcall(health.set, health, name, labels or {}, value)
end

local function _validate_optional_positive(config, field)
  local value = config[field]
  if value == nil then
    return true
  end
  if type(value) ~= "number" or value <= 0 then
    return _validation_error(field .. " must be a positive number")
  end
  return true
end

-- Case-insensitive header lookup (nginx may pass headers with different casing).
local function _get_header(headers, canonical_name)
  if not headers or type(headers) ~= "table" then
    return nil
  end
  local v = headers[canonical_name]
  if v ~= nil then
    return v
  end
  return headers[string_lower(canonical_name)]
end

local function _date_key(now)
  return os_date("!%Y%m%d", now)
end

local function _seconds_until_midnight_utc(now)
  local next_midnight = (floor(now / 86400) + 1) * 86400
  return max(1, ceil(next_midnight - now))
end

local function _serialize_bucket_state(tokens, last_refill)
  return string_format("%.6f:%.6f", tokens, last_refill)
end

local function _deserialize_bucket_state(raw)
  if type(raw) ~= "string" then
    return nil, nil
  end
  local separator = string_find(raw, ":", 1, true)
  if not separator then
    return nil, nil
  end

  local tokens = tonumber(string_sub(raw, 1, separator - 1))
  local last_refill = tonumber(string_sub(raw, separator + 1))
  if not tokens or not last_refill then
    return nil, nil
  end

  return tokens, last_refill
end

-- Max body size to scan for word estimate; avoids slow scan on multi-MB bodies (PERF-2).
local MAX_BODY_SCAN_BYTES = 1048576

-- Zero-allocation path: scan for "content" fields in messages array without JSON decode.
local function _simple_word_estimate(request_context)
  local body = ""
  if request_context and type(request_context.body) == "string" then
    body = request_context.body
  end
  if body == "" then
    return 0
  end
  if #body > MAX_BODY_SCAN_BYTES then
    body = string_sub(body, 1, MAX_BODY_SCAN_BYTES)
  end

  local messages_start = string_find(body, "\"messages\"", 1, true)
  if messages_start then
    local array_start = string_find(body, "[", messages_start, true)
    local array_end = array_start and string_find(body, "]", array_start, true)
    if array_start and array_end then
      local segment = string_sub(body, array_start, array_end)
      local marker = "\"content\":\""
      local marker_len = #marker
      local position = 1
      local char_count = 0

      while true do
        local start_pos = string_find(segment, marker, position, true)
        if not start_pos then
          break
        end
        local content_start = start_pos + marker_len
        local content_end = string_find(segment, "\"", content_start, true)
        if not content_end then
          break
        end
        char_count = char_count + (content_end - content_start)
        position = content_end + 1
      end

      return ceil(char_count / 4)
    end
  end

  return ceil(#body / 4)
end

local function _check_tpd_budget(dict, key, config, cost, now)
  local ttl = _seconds_until_midnight_utc(now)
  local new_total, incr_err = dict:incr(key, cost, 0, ttl)
  if incr_err then
    _log_warn("check_tpd_budget key=", key, " incr_err=", incr_err, " fail_open=true")
    return {
      allowed = true,
      remaining = nil,
      retry_after = nil,
      dict_error = incr_err,
    }
  end

  if new_total > config.tokens_per_day then
    local cur = dict:get(key) or 0
    dict:set(key, max(0, cur - cost))
    return {
      allowed = false,
      remaining = max(0, config.tokens_per_day - (new_total - cost)),
      retry_after = _seconds_until_midnight_utc(now),
    }
  end

  return {
    allowed = true,
    remaining = config.tokens_per_day - new_total,
    retry_after = nil,
  }
end

local function _refund_tpm(dict, key, config, refund, now)
  if refund <= 0 then
    return
  end

  local bucket = config._tpm_bucket_config
  local burst = bucket.burst
  local tokens = burst
  local last_refill = now

  local raw = dict:get(key)
  if raw ~= nil then
    local parsed_tokens, parsed_last_refill = _deserialize_bucket_state(raw)
    if parsed_tokens and parsed_last_refill then
      tokens = parsed_tokens
      last_refill = parsed_last_refill
    end
  end

  local elapsed = max(0, now - last_refill)
  local refilled = min(tokens + elapsed * bucket.tokens_per_second, burst)
  local refunded = min(refilled + refund, burst)
  dict:set(key, _serialize_bucket_state(refunded, now))
end

function _M.validate_config(config)
  if type(config) ~= "table" then
    return _validation_error("config must be a table")
  end
  if config.algorithm ~= "token_bucket_llm" then
    return _validation_error("algorithm must be token_bucket_llm")
  end
  if type(config.tokens_per_minute) ~= "number" or config.tokens_per_minute <= 0 then
    return _validation_error("tokens_per_minute must be a positive number")
  end

  local ok, err = _validate_optional_positive(config, "tokens_per_day")
  if not ok then
    return nil, err
  end

  if config.burst_tokens == nil then
    config.burst_tokens = config.tokens_per_minute
  elseif type(config.burst_tokens) ~= "number" or config.burst_tokens <= 0 then
    return _validation_error("burst_tokens must be a positive number")
  end
  if config.burst_tokens < config.tokens_per_minute then
    return _validation_error("burst_tokens must be >= tokens_per_minute")
  end

  ok, err = _validate_optional_positive(config, "max_tokens_per_request")
  if not ok then
    return nil, err
  end
  ok, err = _validate_optional_positive(config, "max_prompt_tokens")
  if not ok then
    return nil, err
  end
  ok, err = _validate_optional_positive(config, "max_completion_tokens")
  if not ok then
    return nil, err
  end

  if config.default_max_completion == nil then
    config.default_max_completion = 1000
  elseif type(config.default_max_completion) ~= "number" or config.default_max_completion <= 0 then
    return _validation_error("default_max_completion must be a positive number")
  end

  if config.token_source == nil then
    config.token_source = {}
  elseif type(config.token_source) ~= "table" then
    return _validation_error("token_source must be a table")
  end

  local estimator = config.token_source.estimator or "simple_word"
  if type(estimator) ~= "string" then
    return _validation_error("token_source.estimator must be a string")
  end
  if not VALID_ESTIMATORS[estimator] then
    return _validation_error("token_source.estimator must be simple_word or header_hint")
  end

  config.token_source.estimator = estimator
  config._tpm_bucket_config = {
    tokens_per_second = config.tokens_per_minute / 60,
    burst = config.burst_tokens,
  }

  return true
end

function _M.estimate_prompt_tokens(config, request_context)
  local estimator = config and config.token_source and config.token_source.estimator or "simple_word"
  if estimator == "header_hint" then
    local headers = request_context and request_context.headers
    local hint = _get_header(headers, "X-Token-Estimate")
    local parsed_hint = tonumber(hint)
    if parsed_hint then
      return ceil(parsed_hint)
    end
  end
  -- simple_word estimator.
  return _simple_word_estimate(request_context)
end

function _M.check(dict, key, config, request_context, now)
  local current_now = now or ngx.now()
  local prompt_tokens = _M.estimate_prompt_tokens(config, request_context)

  if config.max_prompt_tokens and prompt_tokens > config.max_prompt_tokens then
    local result = _set_reject("prompt_tokens_exceeded")
    result.prompt_tokens = prompt_tokens
    result.max_prompt_tokens = config.max_prompt_tokens
    return result
  end

  local max_completion = config.default_max_completion
  if request_context and type(request_context.max_tokens) == "number" and request_context.max_tokens > 0 then
    max_completion = request_context.max_tokens
  end
  if config.max_completion_tokens and max_completion > config.max_completion_tokens then
    max_completion = config.max_completion_tokens
  end

  local estimated_total = prompt_tokens + max_completion
  if config.max_tokens_per_request and estimated_total > config.max_tokens_per_request then
    local result = _set_reject("max_tokens_per_request_exceeded")
    result.estimated_total = estimated_total
    result.max_tokens_per_request = config.max_tokens_per_request
    return result
  end

  local tpm_key = TPM_KEY_PREFIX .. key
  local tpm_result = token_bucket.check(dict, tpm_key, config._tpm_bucket_config, estimated_total)
  if not tpm_result.allowed then
    local result = _set_reject("tpm_exceeded")
    result.remaining_tokens = tpm_result.remaining
    result.limit_tokens = config.tokens_per_minute
    result.retry_after = tpm_result.retry_after
    result.estimated_total = estimated_total
    return result
  end

  local tpd_result = nil
  if config.tokens_per_day then
    local tpd_key = TPD_KEY_PREFIX .. key .. ":" .. _date_key(current_now)
    tpd_result = _check_tpd_budget(dict, tpd_key, config, estimated_total, current_now)
    if not tpd_result.allowed then
      _refund_tpm(dict, tpm_key, config, estimated_total, current_now)
      local result = _set_reject("tpd_exceeded")
      result.remaining_tokens = tpd_result.remaining
      result.limit_tokens = config.tokens_per_day
      result.retry_after = tpd_result.retry_after
      result.estimated_total = estimated_total
      return result
    end
  end

  _clear_result()
  _result.allowed = true
  _result.estimated_total = estimated_total
  _result.prompt_tokens = prompt_tokens
  _result.reserved = estimated_total
  _result.remaining_tpm = tpm_result.remaining
  _result.remaining_tpd = tpd_result and tpd_result.remaining or nil
  _result.limit_tpm = config.tokens_per_minute
  _result.limit_tpd = config.tokens_per_day
  return _result
end

function _M.reconcile(dict, key, config, estimated_total, actual_total, now)
  local current_now = now or ngx.now()
  local estimated = tonumber(estimated_total) or 0
  local actual = tonumber(actual_total) or 0
  local unused = estimated - actual

  if unused > 0 then
    local tpm_key = TPM_KEY_PREFIX .. key
    _refund_tpm(dict, tpm_key, config, unused, current_now)

    if config.tokens_per_day then
      local tpd_key = TPD_KEY_PREFIX .. key .. ":" .. _date_key(current_now)
      local current = dict:get(tpd_key) or 0
      dict:set(tpd_key, max(0, current - unused))
    end
  else
    unused = 0
  end

  if estimated > 0 then
    _set_metric("fairvisor_token_estimation_accuracy_ratio", {
      route = tostring(config and config._metric_route or ""),
      estimator = tostring(config and config.token_source and config.token_source.estimator or "simple_word"),
    }, actual / estimated)
  end
  if actual > 0 then
    _inc_metric("fairvisor_tokens_consumed_total", {
      type = "actual",
      policy = tostring(config and config._metric_policy or ""),
      route = tostring(config and config._metric_route or ""),
    }, actual)
  end
  if unused > 0 then
    _inc_metric("fairvisor_token_reservation_unused_total", {
      route = tostring(config and config._metric_route or ""),
    }, unused)
  end

  _reconcile_result.refunded = unused
  _reconcile_result.actual = actual
  _reconcile_result.estimated = estimated
  return _reconcile_result
end

-- Returns JSON string (body for 429 response). Caller sets status and Content-Type.
function _M.build_error_response(reason, details)
  local message = "Rate limit exceeded"
  if reason and reason ~= "" then
    message = message .. ": " .. tostring(reason)
  end

  local payload = {
    error = {
      message = message,
      type = "rate_limit_error",
      code = "rate_limit_exceeded",
    },
  }
  if details and type(details) == "table" then
    payload.error.details = details
  end

  local encoded = _encode_json(payload)
  if encoded then
    return encoded
  end

  local escaped_message = string_gsub(string_gsub(message, "\\", "\\\\"), '"', '\\"')
  return "{\"error\":{\"message\":\"" .. escaped_message .. "\",\"type\":\"rate_limit_error\",\"code\":\"rate_limit_exceeded\"}}"
end

return _M
