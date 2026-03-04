local tonumber = tonumber
local type = type
local ipairs = ipairs
local max = math.max
local string_sub = string.sub
local string_gmatch = string.gmatch
local DEFAULT_JSON_PATHS = { "$.usage" }
local DEFAULT_MAX_PARSEABLE_BODY_BYTES = 1048576
local DEFAULT_MAX_STREAM_BUFFER_BYTES = 65536
local DEFAULT_MAX_PARSE_TIME_MS = 2
local DEFAULT_FALLBACK = "estimator_with_audit_flag"
local _M = {}
local utils = require("fairvisor.utils")
local _json_lib

local function _log_err(...)
  if ngx and ngx.log then ngx.log(ngx.ERR, ...) end
end
local _llm_limiter

local function _now()
  if ngx and ngx.now then
    return ngx.now()
  end
  return 0
end

local function _get_json_lib()
  if _json_lib ~= nil then
    return _json_lib
  end
  _json_lib = utils.get_json()
  return _json_lib
end

local function _load_llm_limiter()
  if _llm_limiter ~= nil then
    return _llm_limiter
  end
  local ok, mod = pcall(require, "fairvisor.llm_limiter")
  if ok and mod and type(mod.reconcile) == "function" then
    _llm_limiter = mod
  else
    _llm_limiter = false
  end
  return _llm_limiter
end

local function _to_number(value)
  if value == nil then
    return nil
  end
  local parsed = tonumber(value)
  if parsed == nil or parsed < 0 then
    return nil
  end
  return parsed
end

local function _normalize_usage(usage)
  if type(usage) ~= "table" then
    return nil
  end
  local prompt_tokens = _to_number(usage.prompt_tokens)
  local completion_tokens = _to_number(usage.completion_tokens)
  local total_tokens = _to_number(usage.total_tokens)
  if total_tokens == nil then
    total_tokens = (prompt_tokens or 0) + (completion_tokens or 0)
  end
  return { prompt_tokens = prompt_tokens, completion_tokens = completion_tokens, total_tokens = total_tokens }
end

local function _extract_usage(parsed, json_paths)
  for _, path in ipairs(json_paths) do
    local candidate = _M.extract_json_path(parsed, path)
    if type(candidate) == "table" then
      local usage = _normalize_usage(candidate)
      if usage then
        return usage
      end
    else
      local total = _to_number(candidate)
      if total ~= nil then
        return { prompt_tokens = nil, completion_tokens = nil, total_tokens = total }
      end
    end
  end
  return nil
end

function _M.extract_json_path(obj, path)
  if type(obj) ~= "table" or type(path) ~= "string" or path == "" then
    return nil
  end
  local stripped = path
  if string_sub(stripped, 1, 2) == "$." then
    stripped = string_sub(stripped, 3)
  end
  if stripped == "" then
    return nil
  end
  local current = obj
  for key in string_gmatch(stripped, "[^%.]+") do
    if type(current) ~= "table" then
      return nil
    end
    current = current[key]
    if current == nil then
      return nil
    end
  end
  return current
end

function _M.validate_config(config)
  if type(config) ~= "table" then
    return nil, "config must be a table"
  end
  if config.json_paths == nil then
    config.json_paths = DEFAULT_JSON_PATHS
  end
  if type(config.json_paths) ~= "table" or #config.json_paths == 0 then
    return nil, "json_paths must be a non-empty array"
  end
  for i = 1, #config.json_paths do
    local path = config.json_paths[i]
    if type(path) ~= "string" or path == "" then
      return nil, "json_paths entries must be non-empty strings"
    end
  end
  if config.max_parseable_body_bytes == nil then
    config.max_parseable_body_bytes = DEFAULT_MAX_PARSEABLE_BODY_BYTES
  end
  if type(config.max_parseable_body_bytes) ~= "number" or config.max_parseable_body_bytes <= 0 then
    return nil, "max_parseable_body_bytes must be > 0"
  end
  if config.max_stream_buffer_bytes == nil then
    config.max_stream_buffer_bytes = DEFAULT_MAX_STREAM_BUFFER_BYTES
  end
  if type(config.max_stream_buffer_bytes) ~= "number" or config.max_stream_buffer_bytes <= 0 then
    return nil, "max_stream_buffer_bytes must be > 0"
  end
  if config.max_parse_time_ms == nil then
    config.max_parse_time_ms = DEFAULT_MAX_PARSE_TIME_MS
  end
  if type(config.max_parse_time_ms) ~= "number" or config.max_parse_time_ms <= 0 then
    return nil, "max_parse_time_ms must be > 0"
  end
  if config.fallback == nil then
    config.fallback = DEFAULT_FALLBACK
  end
  if type(config.fallback) ~= "string" or config.fallback == "" then
    return nil, "fallback must be a non-empty string"
  end
  return true
end

function _M.extract_from_response(body, config)
  if type(body) ~= "string" then
    return nil, "json_parse_error", { fallback = true }
  end
  if type(config) ~= "table" then
    return nil, "config_invalid", { fallback = true }
  end
  if #body > config.max_parseable_body_bytes then
    return nil, "body_too_large", { fallback = true }
  end
  local json_lib = _get_json_lib()
  if not json_lib then
    return nil, "json_parse_error", { fallback = true }
  end
  local started = _now()
  local parsed, _ = json_lib.decode(body)
  local parse_time_ms = (_now() - started) * 1000
  if parse_time_ms > config.max_parse_time_ms then
    return nil, "parse_timeout", { fallback = true }
  end
  if not parsed then
    return nil, "json_parse_error", { fallback = true }
  end
  local usage = _extract_usage(parsed, config.json_paths)
  if not usage then
    return nil, "usage_not_found", { fallback = true }
  end
  return {
    prompt_tokens = usage.prompt_tokens,
    completion_tokens = usage.completion_tokens,
    total_tokens = usage.total_tokens,
    cost_source_fallback = false,
  }
end

function _M.extract_from_sse_final(event_data)
  if type(event_data) ~= "string" or event_data == "" then
    return nil
  end
  local json_lib = _get_json_lib()
  if not json_lib then
    return nil
  end
  local parsed, _ = json_lib.decode(event_data)
  if type(parsed) ~= "table" or type(parsed.usage) ~= "table" then
    return nil
  end
  return _normalize_usage(parsed.usage)
end

function _M.reconcile_response(extraction_result, reservation, dict, config, now)
  if extraction_result == nil then
    return { refunded = 0, cost_source_fallback = true }
  end
  if type(reservation) ~= "table" then
    return nil, "reservation must be a table"
  end
  local estimated_total = _to_number(reservation.estimated_total) or 0
  local actual_total = _to_number(extraction_result.total_tokens) or 0
  local unused = estimated_total - actual_total
  if unused > 0 then
    local limiter = _load_llm_limiter()
    if limiter then
      local ok, err = limiter.reconcile(dict, reservation.key, config, estimated_total, actual_total, now)
      if ok == nil then
        _log_err("reconcile_response key=", reservation.key or "", " err=", err or "unknown")
      end
    end
  end
  local estimation_error_ratio
  if actual_total > 0 then
    estimation_error_ratio = estimated_total / actual_total
  end
  return {
    refunded = max(0, unused),
    actual_total = actual_total,
    estimated_total = estimated_total,
    estimation_error_ratio = estimation_error_ratio,
    cost_source_fallback = false,
  }
end

return _M
