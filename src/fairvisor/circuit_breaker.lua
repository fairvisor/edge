local floor = math.floor
local tonumber = tonumber
local type = type
local string_sub = string.sub
local tostring = tostring

--[[
  Budget circuit breaker: opens when estimated spend per minute exceeds a threshold.
  - limit_key: isolates state and rate counters per policy/tenant.
  - cost: additive cost per request (same units as spend_rate_threshold_per_minute).
  - spend_rate_threshold_per_minute: cap; when estimated rate >= threshold, breaker opens.
  - On tripped: returns tripped=true, state="open", reason="circuit_breaker_open", optional alert.
  - When disabled (config.enabled == false): always returns closed without touching dict.
]]

-- Fixed 1-minute rolling window; TTL for rate keys. Configurable window could be added later.
local WINDOW_SIZE_SECONDS = 60
local WINDOW_TTL_SECONDS = 120
local STATE_PREFIX = "cb_state:"
local RATE_PREFIX = "cb_rate:"
local OPEN_PREFIX = "open:"

local _M = {}

local function _log_err(...)
  if ngx and ngx.log then ngx.log(ngx.ERR, ...) end
end

local function _parse_opened_at(state_raw)
  if type(state_raw) ~= "string" then
    return nil
  end

  if string_sub(state_raw, 1, 5) ~= OPEN_PREFIX then
    return nil
  end

  local opened_at = tonumber(string_sub(state_raw, 6))
  if not opened_at then
    return nil
  end

  return opened_at
end

function _M.validate_config(config)
  if config == nil then
    return true
  end

  if type(config) ~= "table" then
    return nil, "circuit_breaker config must be a table"
  end

  if config.enabled ~= nil and type(config.enabled) ~= "boolean" then
    return nil, "circuit_breaker.enabled must be a boolean"
  end

  if not config.enabled then
    return true
  end

  local threshold = config.spend_rate_threshold_per_minute
  if type(threshold) ~= "number" or threshold <= 0 then
    return nil, "circuit_breaker.spend_rate_threshold_per_minute must be a positive number"
  end

  if config.action == nil then
    config.action = "reject"
  end
  if config.action ~= "reject" then
    return nil, "circuit_breaker.action must be reject"
  end

  if config.auto_reset_after_minutes == nil then
    config.auto_reset_after_minutes = 0
  end
  if type(config.auto_reset_after_minutes) ~= "number" or config.auto_reset_after_minutes < 0 then
    return nil, "circuit_breaker.auto_reset_after_minutes must be a non-negative number"
  end

  if config.alert == nil then
    config.alert = false
  end
  if type(config.alert) ~= "boolean" then
    return nil, "circuit_breaker.alert must be a boolean"
  end

  return true
end

function _M.build_state_key(limit_key)
  return STATE_PREFIX .. limit_key
end

function _M.build_rate_key(limit_key, window_start)
  return RATE_PREFIX .. limit_key .. ":" .. window_start
end

function _M.check(dict, config, limit_key, cost, now)
  if config and config.enabled == false then
    return {
      tripped = false,
      state = "closed",
      spend_rate = nil,
      threshold = nil,
      reason = nil,
      alert = nil,
    }
  end

  local state_key = _M.build_state_key(limit_key)
  local state_raw = dict:get(state_key)

  if state_raw ~= nil then
    local opened_at = _parse_opened_at(state_raw)
    if opened_at then
      if config.auto_reset_after_minutes > 0 then
        local elapsed_minutes = (now - opened_at) / WINDOW_SIZE_SECONDS
        if elapsed_minutes < config.auto_reset_after_minutes then
          return {
            tripped = true,
            state = "open",
            spend_rate = nil,
            threshold = nil,
            reason = "circuit_breaker_open",
            alert = nil,
          }
        end

        dict:delete(state_key)
      else
        return {
          tripped = true,
          state = "open",
          spend_rate = nil,
          threshold = nil,
          reason = "circuit_breaker_open",
          alert = nil,
        }
      end
    end
  end

  local current_window = floor(now / WINDOW_SIZE_SECONDS) * WINDOW_SIZE_SECONDS
  local previous_window = current_window - WINDOW_SIZE_SECONDS
  local elapsed = now - current_window
  local weight = elapsed / WINDOW_SIZE_SECONDS

  local current_key = _M.build_rate_key(limit_key, current_window)
  local previous_key = _M.build_rate_key(limit_key, previous_window)

  if cost == nil or cost <= 0 then
    cost = 0
  end

  -- Fail-open: if dict:incr fails (e.g. no memory), return closed and do not trip.
  local current_total, incr_err = dict:incr(current_key, cost, 0, WINDOW_TTL_SECONDS)
  if current_total == nil then
    _log_err("check limit_key=", limit_key or "", " error=", incr_err or "unknown")
    return {
      tripped = false,
      state = "closed",
      spend_rate = nil,
      threshold = nil,
      reason = nil,
      alert = nil,
    }
  end

  local previous_total = dict:get(previous_key) or 0
  local spend_rate = previous_total * (1 - weight) + current_total

  if spend_rate >= config.spend_rate_threshold_per_minute then
    local set_ok = dict:set(state_key, OPEN_PREFIX .. tostring(now))
    if not set_ok then
      _log_err("check limit_key=", limit_key or "", " error=dict set state failed")
      return {
        tripped = false,
        state = "closed",
        spend_rate = spend_rate,
        threshold = config.spend_rate_threshold_per_minute,
        reason = nil,
        alert = nil,
      }
    end

    return {
      tripped = true,
      state = "open",
      spend_rate = spend_rate,
      threshold = config.spend_rate_threshold_per_minute,
      reason = "circuit_breaker_open",
      alert = config.alert,
    }
  end

  return {
    tripped = false,
    state = "closed",
    spend_rate = spend_rate,
    threshold = config.spend_rate_threshold_per_minute,
    reason = nil,
    alert = nil,
  }
end

function _M.reset(dict, limit_key, now)
  local state_key = _M.build_state_key(limit_key)
  dict:delete(state_key)

  if now == nil then
    now = ngx.now()
  end
  local current_window = floor(now / WINDOW_SIZE_SECONDS) * WINDOW_SIZE_SECONDS
  local previous_window = current_window - WINDOW_SIZE_SECONDS

  dict:delete(_M.build_rate_key(limit_key, current_window))
  dict:delete(_M.build_rate_key(limit_key, previous_window))
end

return _M
