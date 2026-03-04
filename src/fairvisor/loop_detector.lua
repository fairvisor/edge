local floor = math.floor
local next = next
local pairs = pairs
local tostring = tostring
local type = type
local table_concat = table.concat
local table_sort = table.sort

local KEY_PREFIX = "loop:"

local function _log_err(...)
  if ngx and ngx.log then ngx.log(ngx.ERR, ...) end
end
local REASON_LOOP_DETECTED = "loop_detected"
local VALID_ACTIONS = {
  reject = true,
  throttle = true,
  warn = true,
}

-- Reusable buffers for build_fingerprint (zero allocations on hot path). Volatile: valid only until next build_fingerprint().
local _parts = {}
local _keys = {}

local _M = {}

local function _is_positive_integer(value)
  return type(value) == "number" and value > 0 and floor(value) == value
end

local function _append_sorted_key_values(parts, values, scratch_keys)
  if type(values) ~= "table" or next(values) == nil then
    return
  end

  while #scratch_keys > 0 do
    scratch_keys[#scratch_keys] = nil
  end
  for key in pairs(values) do
    scratch_keys[#scratch_keys + 1] = key
  end
  table_sort(scratch_keys)

  for i = 1, #scratch_keys do
    local key = scratch_keys[i]
    parts[#parts + 1] = tostring(key) .. "=" .. tostring(values[key])
  end
end

function _M.validate_config(config)
  if config == nil then
    return true
  end

  if type(config) ~= "table" then
    return nil, "loop_detection config must be a table"
  end

  local loop_detection = config
  if config.loop_detection ~= nil then
    if type(config.loop_detection) ~= "table" then
      return nil, "loop_detection must be a table"
    end
    loop_detection = config.loop_detection
  end

  if loop_detection.enabled == nil or loop_detection.enabled == false then
    return true
  end

  if type(loop_detection.enabled) ~= "boolean" then
    return nil, "enabled must be a boolean"
  end

  if loop_detection.window_seconds == nil then
    return nil, "when enabled is true, window_seconds is required"
  end
  if not _is_positive_integer(loop_detection.window_seconds) then
    return nil, "window_seconds must be a positive integer"
  end

  if loop_detection.threshold_identical_requests == nil then
    return nil, "when enabled is true, threshold_identical_requests is required"
  end
  if not _is_positive_integer(loop_detection.threshold_identical_requests) then
    return nil, "threshold_identical_requests must be a positive integer"
  end

  if loop_detection.threshold_identical_requests < 2 then
    return nil, "threshold_identical_requests must be >= 2"
  end

  if loop_detection.action == nil then
    loop_detection.action = "reject"
  end

  if type(loop_detection.action) ~= "string" or not VALID_ACTIONS[loop_detection.action] then
    return nil, "action must be one of reject, throttle, warn"
  end

  if loop_detection.similarity == nil then
    loop_detection.similarity = "exact"
  end

  if loop_detection.similarity ~= "exact" then
    return nil, "similarity must be exact"
  end

  return true
end

function _M.build_fingerprint(method, path, query_params, body_hash, limit_key_values)
  while #_parts > 0 do
    _parts[#_parts] = nil
  end
  _parts[1] = tostring(method or "")
  _parts[2] = tostring(path or "")

  _append_sorted_key_values(_parts, query_params, _keys)

  if body_hash ~= nil then
    _parts[#_parts + 1] = tostring(body_hash)
  end

  _append_sorted_key_values(_parts, limit_key_values, _keys)

  return ngx.crc32_short(table_concat(_parts, "|"))
end

function _M.check(dict, config, fingerprint, _now)
  local action = config.action or "reject"
  local key = KEY_PREFIX .. tostring(fingerprint)
  local count, err = dict:incr(key, 1, 0, config.window_seconds)
  if not count then
    _log_err("check key=", key, " err=", err or "unknown")
    return {
      detected = false,
      count = 0,
      action = nil,
      retry_after = nil,
      delay_ms = nil,
      reason = nil,
    }
  end

  if count < config.threshold_identical_requests then
    return {
      detected = false,
      count = count,
      action = nil,
      retry_after = nil,
      delay_ms = nil,
      reason = nil,
    }
  end

  local retry_after, delay_ms
  if action == "reject" then
    retry_after = config.window_seconds
    delay_ms = nil
  elseif action == "throttle" then
    retry_after = nil
    delay_ms = count * 100
  else
    retry_after = nil
    delay_ms = nil
  end

  return {
    detected = true,
    action = action,
    count = count,
    reason = REASON_LOOP_DETECTED,
    retry_after = retry_after,
    delay_ms = delay_ms,
  }
end

return _M
