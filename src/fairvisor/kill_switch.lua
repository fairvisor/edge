local ipairs = ipairs
local type = type
local string_match = string.match

local utils = require("fairvisor.utils")

local ALLOWED_SCOPE_PREFIX = {
  jwt = true,
  header = true,
  query = true,
  ip = true,
  ua = true,
}

local _M = {}

local function _is_valid_scope_key(scope_key)
  if type(scope_key) ~= "string" or scope_key == "" then
    return false
  end

  local scope_prefix, scope_name = string_match(scope_key, "^([a-z]+):([%w_-]+)$")
  if not scope_prefix or not scope_name then
    return false
  end

  return ALLOWED_SCOPE_PREFIX[scope_prefix] == true
end

--- Parse an ISO 8601 UTC timestamp to epoch seconds. Delegates to fairvisor.utils.
-- @param s (string) timestamp like "2026-02-03T14:00:00Z"
-- @return number|nil epoch seconds on success, nil on parse failure
function _M.parse_iso8601(s)
  local epoch, _ = utils.parse_iso8601(s)
  return epoch
end

--- Validate kill-switch entries from a policy bundle at load time.
-- @param kill_switches (table|nil) array of kill-switch entries
-- @return true on success (or if nil/empty)
-- @return nil, string on validation error
function _M.validate(kill_switches)
  if kill_switches == nil then
    return true
  end

  if type(kill_switches) ~= "table" then
    return nil, "kill_switches must be a table"
  end

  for i, kill_switch in ipairs(kill_switches) do
    if type(kill_switch) ~= "table" then
      return nil, "kill_switches[" .. i .. "] must be a table"
    end

    if not _is_valid_scope_key(kill_switch.scope_key) then
      return nil, "kill_switches[" .. i .. "].scope_key must match ^(jwt|header|query|ip|ua):[A-Za-z0-9_-]+$"
    end

    if type(kill_switch.scope_value) ~= "string" or kill_switch.scope_value == "" then
      return nil, "kill_switches[" .. i .. "].scope_value must be a non-empty string"
    end

    if kill_switch.route ~= nil then
      if type(kill_switch.route) ~= "string" or kill_switch.route == "" then
        return nil, "kill_switches[" .. i .. "].route must be a non-empty string when set"
      end
      if string_match(kill_switch.route, "^/") == nil then
        return nil, "kill_switches[" .. i .. "].route must start with /"
      end
    end

    if kill_switch.reason ~= nil and type(kill_switch.reason) ~= "string" then
      return nil, "kill_switches[" .. i .. "].reason must be a string when set"
    end

    if kill_switch.expires_at ~= nil then
      if type(kill_switch.expires_at) ~= "string" then
        return nil, "kill_switches[" .. i .. "].expires_at must be an ISO 8601 UTC string"
      end

      local expires_epoch = utils.parse_iso8601(kill_switch.expires_at)
      if not expires_epoch then
        return nil, "kill_switches[" .. i .. "].expires_at must be valid ISO 8601 UTC (YYYY-MM-DDTHH:MM:SSZ)"
      end
      kill_switch._expires_epoch = expires_epoch
    end
  end

  return true
end

--- Check if the current request matches any active kill-switch.
-- @param kill_switches (table) validated kill-switch array from the bundle
-- @param descriptors (table) map of descriptor key -> value for this request
-- @param route (string) the matched route path for this request
-- @param now (number) current epoch time (ngx.now())
-- @return table { matched=bool [, reason, scope_key, scope_value, route, ks_reason] }
function _M.check(kill_switches, descriptors, route, now)
  local result = {
    matched = false,
    reason = nil,
    scope_key = nil,
    scope_value = nil,
    route = nil,
    ks_reason = nil,
  }

  if kill_switches == nil or #kill_switches == 0 then
    return result
  end

  for _, kill_switch in ipairs(kill_switches) do
    local expires_epoch = kill_switch._expires_epoch
    -- Fallback: parse at check time if validate() was skipped (e.g. raw bundle).
    -- Normal flow uses validate() at load, so _expires_epoch is pre-set.
    if expires_epoch == nil and kill_switch.expires_at ~= nil then
      expires_epoch = _M.parse_iso8601(kill_switch.expires_at)
      if expires_epoch then
        kill_switch._expires_epoch = expires_epoch
      end
    end

    if expires_epoch == nil or expires_epoch >= now then
      local scope_value = descriptors and descriptors[kill_switch.scope_key]
      if scope_value ~= nil and scope_value == kill_switch.scope_value then
        if kill_switch.route == nil or kill_switch.route == route then
          result.matched = true
          result.reason = "kill_switch"
          result.scope_key = kill_switch.scope_key
          result.scope_value = kill_switch.scope_value
          result.route = kill_switch.route
          result.ks_reason = kill_switch.reason
          return result
        end
      end
    end
  end

  return result
end

return _M
