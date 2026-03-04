local type = type
local pcall = pcall

local SHUTDOWN_WATCHDOG_SECONDS = 31536000

local _M = {}

local _state = {
  saas_client = nil,
  health = nil,
  timer_registered = false,
}

local function _log_err(...)
  if ngx and ngx.log then ngx.log(ngx.ERR, ...) end
end
local function _log_notice(...)
  if ngx and ngx.log then ngx.log(ngx.NOTICE, ...) end
end

local function _flush_events()
  if not _state.saas_client or type(_state.saas_client.flush_events) ~= "function" then
    return
  end

  local flushed, err = _state.saas_client.flush_events()
  if err then
    _log_err("shutdown_handler event_flush_failed err=", err)
    return
  end

  _log_notice("shutdown_handler flushed_events=", flushed or 0)
end

local function _set_shutting_down()
  if not _state.health or type(_state.health.set_shutting_down) ~= "function" then
    return
  end

  local ok, err = pcall(_state.health.set_shutting_down)
  if not ok then
    _log_err("shutdown_handler health_set_shutting_down_failed err=", err)
  end
end

function _M.shutdown_handler()
  _log_notice("shutdown_handler graceful_shutdown_initiated")
  _set_shutting_down()
  _flush_events()
  _log_notice("shutdown_handler shutdown_complete")
  return true
end

function _M.init(deps)
  deps = deps or {}
  _state.saas_client = deps.saas_client
  _state.health = deps.health

  if _state.timer_registered then
    return true
  end

  local n = (deps.ngx ~= nil) and deps.ngx or ngx
  if not n or not n.timer or type(n.timer.at) ~= "function" then
    return nil, "timer_unavailable"
  end

  local ok, err = n.timer.at(SHUTDOWN_WATCHDOG_SECONDS, function(premature)
    if premature then
      _M.shutdown_handler()
    end
  end)

  if not ok then
    _log_err("init timer_registration_failed err=", err)
    return nil, err
  end

  _state.timer_registered = true
  return true
end

return _M
