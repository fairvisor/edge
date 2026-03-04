local tonumber = tonumber
local type = type
local os_getenv = os.getenv

local DEFAULT_CONFIG_POLL_INTERVAL = 30
local DEFAULT_HEARTBEAT_INTERVAL = 5
local DEFAULT_EVENT_FLUSH_INTERVAL = 60
local DEFAULT_SHARED_DICT_SIZE = "128m"
local DEFAULT_LOG_LEVEL = "info"
local DEFAULT_MODE = "decision_service"

local _M = {}

local function _get_env(name)
  return os_getenv(name)
end

local function _load_number(name, fallback)
  local value = _get_env(name)
  if value == nil or value == "" then
    return fallback
  end

  return tonumber(value) or fallback
end

function _M.load()
  local config = {
    edge_id = _get_env("FAIRVISOR_EDGE_ID"),
    edge_token = _get_env("FAIRVISOR_EDGE_TOKEN"),
    saas_url = _get_env("FAIRVISOR_SAAS_URL"),
    config_file = _get_env("FAIRVISOR_CONFIG_FILE"),
    config_poll_interval = _load_number("FAIRVISOR_CONFIG_POLL_INTERVAL", DEFAULT_CONFIG_POLL_INTERVAL),
    heartbeat_interval = _load_number("FAIRVISOR_HEARTBEAT_INTERVAL", DEFAULT_HEARTBEAT_INTERVAL),
    event_flush_interval = _load_number("FAIRVISOR_EVENT_FLUSH_INTERVAL", DEFAULT_EVENT_FLUSH_INTERVAL),
    shared_dict_size = _get_env("FAIRVISOR_SHARED_DICT_SIZE") or DEFAULT_SHARED_DICT_SIZE,
    log_level = _get_env("FAIRVISOR_LOG_LEVEL") or DEFAULT_LOG_LEVEL,
    mode = _get_env("FAIRVISOR_MODE") or DEFAULT_MODE,
    backend_url = _get_env("FAIRVISOR_BACKEND_URL"),
    debug_session_secret = _get_env("FAIRVISOR_DEBUG_SESSION_SECRET"),
  }

  return config
end

function _M.is_standalone(config)
  if type(config) ~= "table" then
    return false
  end

  return config.config_file ~= nil and config.config_file ~= "" and (config.saas_url == nil or config.saas_url == "")
end

local function _is_positive_number(value)
  return type(value) == "number" and value > 0
end

function _M.validate(config)
  if type(config) ~= "table" then
    return nil, "config must be a table"
  end

  if config.mode ~= "decision_service" and config.mode ~= "reverse_proxy" then
    return nil, "FAIRVISOR_MODE must be decision_service or reverse_proxy"
  end

  if config.mode == "reverse_proxy" and (config.backend_url == nil or config.backend_url == "") then
    return nil, "FAIRVISOR_BACKEND_URL is required when FAIRVISOR_MODE=reverse_proxy"
  end

  if config.saas_url ~= nil and config.saas_url ~= "" then
    if config.edge_id == nil or config.edge_id == "" then
      return nil, "required environment variable FAIRVISOR_EDGE_ID is not set for SaaS mode"
    end
    if config.edge_token == nil or config.edge_token == "" then
      return nil, "required environment variable FAIRVISOR_EDGE_TOKEN is not set for SaaS mode"
    end
  else
    if config.config_file == nil or config.config_file == "" then
      return nil, "either FAIRVISOR_SAAS_URL or FAIRVISOR_CONFIG_FILE must be set"
    end
  end

  if not _is_positive_number(config.config_poll_interval) then
    return nil, "FAIRVISOR_CONFIG_POLL_INTERVAL must be a positive number"
  end

  if not _is_positive_number(config.heartbeat_interval) then
    return nil, "FAIRVISOR_HEARTBEAT_INTERVAL must be a positive number"
  end

  if not _is_positive_number(config.event_flush_interval) then
    return nil, "FAIRVISOR_EVENT_FLUSH_INTERVAL must be a positive number"
  end

  return true
end

return _M
