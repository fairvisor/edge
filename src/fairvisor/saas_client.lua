local floor = math.floor
local min = math.min
local abs = math.abs
local random = math.random
local type = type
local table_remove = table.remove

local utils = require("fairvisor.utils")
local json_lib = utils.get_json()
local EDGE_VERSION = require("fairvisor.version")

local DEFAULT_HEARTBEAT_INTERVAL = 5
local DEFAULT_EVENT_FLUSH_INTERVAL = 60
local DEFAULT_CONFIG_POLL_INTERVAL = 30
local DEFAULT_MAX_BATCH_SIZE = 100
local DEFAULT_MAX_BUFFER_SIZE = 1000
local MAX_BACKOFF_SECONDS = 60
local CLOCK_SKEW_THRESHOLD_SECONDS = 10
local CIRCUIT_OPEN_AFTER_FAILURES = 5
local CIRCUIT_HALF_OPEN_AFTER_SECONDS = 30
local CIRCUIT_CLOSE_AFTER_HALF_OPEN_SUCCESSES = 2

local STATE_CLOSED = "closed"
local STATE_OPEN = "open"
local STATE_HALF_OPEN = "half_open"

local _M = {}

local function _log_err(...)
  if ngx and ngx.log then ngx.log(ngx.ERR, ...) end
end
local function _log_warn(...)
  if ngx and ngx.log then ngx.log(ngx.WARN, ...) end
end

-- Optional deps.http_client: post(url, body, headers) and get(url, headers) return
-- (response, err); response has .status and .body. For heartbeat/config, .body as
-- table (parsed JSON) is used for server_time and config payload.

local _state = {
  initialized = false,
  config = nil,
  deps = nil,
  start_time = 0,
  event_buffer = {},
  consecutive_failures = 0,
  half_open_successes = 0,
  circuit_state = STATE_CLOSED,
  opened_at = 0,
  seq_counter = 0,
  clock_skew_suspected = false,
  clock_skew_seconds = 0,
  heartbeat_attempt = 0,
  heartbeat_next_retry_at = 0,
  event_attempt = 0,
  event_next_retry_at = 0,
  config_attempt = 0,
  config_next_retry_at = 0,
  register_attempt = 0,
  register_next_retry_at = 0,
  last_config_poll_at = 0,
}

local function _http_client()
  if _state.deps and _state.deps.http_client then
    return _state.deps.http_client
  end

  local ok, resty_http = pcall(require, "resty.http")
  if not ok then
    return nil, "http client is not configured"
  end

  local connect_timeout = _state.config.http_connect_timeout or 5
  local send_timeout = _state.config.http_send_timeout or 10

  return {
    post = function(_, url, body, headers)
      local client = resty_http.new()
      local response, err = client:request_uri(url, {
        method = "POST",
        headers = headers,
        body = body,
        connect_timeout = connect_timeout,
        send_timeout = send_timeout,
      })
      if err then
        return nil, err
      end
      return response, nil
    end,
    get = function(_, url, headers)
      local client = resty_http.new()
      local response, err = client:request_uri(url, {
        method = "GET",
        headers = headers,
        connect_timeout = connect_timeout,
        send_timeout = send_timeout,
      })
      if err then
        return nil, err
      end
      return response, nil
    end,
  }
end

local function _auth_header()
  local token = _state.config.edge_token
  if type(token) ~= "string" then
    return "Bearer "
  end
  -- Defensive: reject tokens that could inject CR/LF into HTTP headers.
  if token:find("[\r\n]") then
    return "Bearer "
  end
  return "Bearer " .. token
end

local function _is_non_retriable_status(status)
  return status == 401 or status == 403 or status == 404
end

local function _compute_backoff(attempt)
  local base = min(2 ^ attempt, MAX_BACKOFF_SECONDS)
  local jitter = random()
  return base + jitter
end

local function _set_reachable(value)
  if _state.deps and _state.deps.health and _state.deps.health.set then
    _state.deps.health:set("fairvisor_saas_reachable", {}, value)
  end
end

local function _inc_events_sent(status)
  if _state.deps and _state.deps.health and _state.deps.health.inc then
    _state.deps.health:inc("fairvisor_events_sent_total", { status = status }, 1)
  end
end

local function _inc_saas_call(operation, status)
  if _state.deps and _state.deps.health and _state.deps.health.inc then
    _state.deps.health:inc("fairvisor_saas_calls_total", { operation = operation, status = status }, 1)
  end
end

local function _record_failure()
  _state.consecutive_failures = _state.consecutive_failures + 1
  _state.half_open_successes = 0

  if _state.consecutive_failures >= CIRCUIT_OPEN_AFTER_FAILURES and _state.circuit_state == STATE_CLOSED then
    _state.circuit_state = STATE_OPEN
    _state.opened_at = ngx.now()
    _set_reachable(0)
    _log_warn("_record_failure msg=saas_circuit_open details=", _state.consecutive_failures)
  elseif _state.circuit_state == STATE_HALF_OPEN then
    _state.circuit_state = STATE_OPEN
    _state.opened_at = ngx.now()
    _set_reachable(0)
    _log_warn("_record_failure msg=saas_circuit_reopened details=", _state.consecutive_failures)
  end
end

local function _record_success()
  if _state.circuit_state == STATE_HALF_OPEN then
    _state.half_open_successes = _state.half_open_successes + 1
    if _state.half_open_successes >= CIRCUIT_CLOSE_AFTER_HALF_OPEN_SUCCESSES then
      _state.circuit_state = STATE_CLOSED
      _state.consecutive_failures = 0
      _state.half_open_successes = 0
      _set_reachable(1)
    end
    return
  end

  _state.consecutive_failures = 0
  _set_reachable(1)
end

local function _circuit_breaker_open()
  return _state.circuit_state == STATE_OPEN
end

local function _should_retry(kind)
  local now = ngx.now()
  if kind == "heartbeat" then
    return now >= _state.heartbeat_next_retry_at
  end
  if kind == "event" then
    return now >= _state.event_next_retry_at
  end
  if kind == "config" then
    return now >= _state.config_next_retry_at
  end
  return now >= _state.register_next_retry_at
end

local function _schedule_retry(kind)
  if kind == "heartbeat" then
    _state.heartbeat_next_retry_at = ngx.now() + _compute_backoff(_state.heartbeat_attempt)
    _state.heartbeat_attempt = _state.heartbeat_attempt + 1
    return
  end
  if kind == "event" then
    _state.event_next_retry_at = ngx.now() + _compute_backoff(_state.event_attempt)
    _state.event_attempt = _state.event_attempt + 1
    return
  end
  if kind == "config" then
    _state.config_next_retry_at = ngx.now() + _compute_backoff(_state.config_attempt)
    _state.config_attempt = _state.config_attempt + 1
    return
  end

  _state.register_next_retry_at = ngx.now() + _compute_backoff(_state.register_attempt)
  _state.register_attempt = _state.register_attempt + 1
end

local function _clear_retry(kind)
  if kind == "heartbeat" then
    _state.heartbeat_attempt = 0
    _state.heartbeat_next_retry_at = 0
    return
  end
  if kind == "event" then
    _state.event_attempt = 0
    _state.event_next_retry_at = 0
    return
  end
  if kind == "config" then
    _state.config_attempt = 0
    _state.config_next_retry_at = 0
    return
  end

  _state.register_attempt = 0
  _state.register_next_retry_at = 0
end

-- Response.body as table (e.g. parsed JSON) is used for payload.server_time etc.
-- When body is a string, decode JSON via utils.get_json() chain.
local function _extract_payload(response)
  if not response then
    return nil
  end

  if type(response.body) == "table" then
    return response.body
  end

  if type(response.body) == "string" and json_lib then
    local payload, _ = json_lib.decode(response.body)
    if type(payload) == "table" then
      return payload
    end
  end

  return response
end

local function _headers(extra)
  local headers = {
    Authorization = _auth_header(),
  }

  if extra then
    for k, v in pairs(extra) do
      headers[k] = v
    end
  end

  return headers
end

local function _post(url, body, headers)
  local http_client, err = _http_client()
  if not http_client then
    return nil, err
  end

  return http_client:post(url, body, headers)
end

local function _get(url, headers)
  local http_client, err = _http_client()
  if not http_client then
    return nil, err
  end

  return http_client:get(url, headers)
end

local function _ack_config(version, hash, status, err)
  local response, post_err = _post(
    _state.config.saas_url .. "/api/v1/edge/config/ack",
    {
      edge_id = _state.config.edge_id,
      version = version,
      hash = hash,
      status = status,
      error = err,
      timestamp = ngx.now(),
    },
    _headers()
  )

  if post_err then
    _record_failure()
    _schedule_retry("config")
    _inc_saas_call("config_ack", "error")
    return nil, post_err
  end

  if response and response.status and response.status >= 400 then
    if _is_non_retriable_status(response.status) then
      _clear_retry("config")
      _log_err("_ack_config non_retriable_status ", response.status)
      _inc_saas_call("config_ack", "error")
      return nil, "non-retriable"
    end

    _record_failure()
    _schedule_retry("config")
    _inc_saas_call("config_ack", "error")
    return nil, "http_status_" .. response.status
  end

  _record_success()
  _clear_retry("config")
  _inc_saas_call("config_ack", "success")
  return true
end

local function _pull_config_tick()
  if not _should_retry("config") then
    return nil, "backoff"
  end

  local current = _state.deps.bundle_loader:get_current()
  local request_headers = _headers()
  if current and current.hash then
    request_headers["If-None-Match"] = current.hash
  end

  local response, err = _get(_state.config.saas_url .. "/api/v1/edge/config", request_headers)
  if err then
    _record_failure()
    _schedule_retry("config")
    _inc_saas_call("config_pull", "error")
    return nil, err
  end

  if response.status == 304 then
    _record_success()
    _clear_retry("config")
    _inc_saas_call("config_pull", "success")
    return true
  end

  if response.status ~= 200 then
    if _is_non_retriable_status(response.status) then
      _clear_retry("config")
      _log_err("_pull_config_tick non_retriable_status ", response.status)
      _inc_saas_call("config_pull", "error")
      return nil, "non-retriable"
    end

    _record_failure()
    _schedule_retry("config")
    _inc_saas_call("config_pull", "error")
    return nil, "http_status_" .. response.status
  end

  local compiled, load_err = _state.deps.bundle_loader:load_from_string(
    response.body,
    _state.config.signing_key,
    current and current.version or nil
  )

  if compiled then
    _state.deps.bundle_loader:apply(compiled)
    _ack_config(compiled.version, compiled.hash, "applied", nil)
    _clear_retry("config")
    _inc_saas_call("config_pull", "success")
    return true
  end

  _ack_config(nil, nil, "rejected", load_err)
  _clear_retry("config")
  _inc_saas_call("config_pull", "success")
  return nil, load_err
end

local function _check_half_open()
  if _state.circuit_state ~= STATE_OPEN then
    return
  end

  if (ngx.now() - _state.opened_at) >= CIRCUIT_HALF_OPEN_AFTER_SECONDS then
    _state.circuit_state = STATE_HALF_OPEN
    _state.half_open_successes = 0
  end
end

local function _register()
  if not _should_retry("register") then
    return nil, "backoff"
  end

  local payload = {
    edge_id = _state.config.edge_id,
    version = EDGE_VERSION,
    timestamp = ngx.now(),
  }

  local response, err = _post(
    _state.config.saas_url .. "/api/v1/edge/register",
    payload,
    _headers()
  )

  if err then
    _record_failure()
    _schedule_retry("register")
    _inc_saas_call("register", "error")
    return nil, err
  end

  if response.status and response.status >= 400 then
    if _is_non_retriable_status(response.status) then
      _clear_retry("register")
      _log_err("_register non_retriable_status ", response.status)
      _inc_saas_call("register", "error")
      return nil, "non-retriable"
    end

    _record_failure()
    _schedule_retry("register")
    _inc_saas_call("register", "error")
    return nil, "http_status_" .. response.status
  end

  _record_success()
  _clear_retry("register")
  _inc_saas_call("register", "success")
  return true
end

local function _heartbeat_tick()
  if _circuit_breaker_open() then
    _check_half_open()
    if _circuit_breaker_open() then
      return
    end
  end

  if not _should_retry("heartbeat") then
    return
  end

  local current = _state.deps.bundle_loader:get_current()
  local response, err = _post(
    _state.config.saas_url .. "/api/v1/edge/heartbeat",
    {
      edge_id = _state.config.edge_id,
      version = EDGE_VERSION,
      policy_hash = current and current.hash or nil,
      uptime = ngx.now() - _state.start_time,
      timestamp = ngx.now(),
    },
    _headers()
  )

  if err then
    _record_failure()
    _schedule_retry("heartbeat")
    _inc_saas_call("heartbeat", "error")
    return
  end

  if response.status and response.status >= 400 then
    if _is_non_retriable_status(response.status) then
      _clear_retry("heartbeat")
      _log_err("_heartbeat_tick non_retriable_status ", response.status)
      _inc_saas_call("heartbeat", "error")
      return
    end

    _record_failure()
    _schedule_retry("heartbeat")
    _inc_saas_call("heartbeat", "error")
    return
  end

  _record_success()
  _clear_retry("heartbeat")
  _inc_saas_call("heartbeat", "success")

  local payload = _extract_payload(response)
  if payload and payload.server_time then
    local skew = abs(ngx.now() - payload.server_time)
    if skew > CLOCK_SKEW_THRESHOLD_SECONDS then
      _state.clock_skew_suspected = true
      _state.clock_skew_seconds = skew
    end
  end

  if payload and payload.config_update_available then
    _M.pull_config()
  elseif (ngx.now() - _state.last_config_poll_at) >= _state.config.config_poll_interval then
    _state.last_config_poll_at = ngx.now()
    _M.pull_config()
  end
end

local function _flush_once()
  if #_state.event_buffer == 0 then
    return 0
  end

  if _circuit_breaker_open() then
    _check_half_open()
    if _circuit_breaker_open() then
      return 0
    end
  end

  if not _should_retry("event") then
    return 0
  end

  local batch_size = min(#_state.event_buffer, _state.config.max_batch_size)
  local batch = {}
  for i = 1, batch_size do
    batch[i] = _state.event_buffer[i]
  end

  local idempotency_key = "batch_"
    .. _state.config.edge_id
    .. "_"
    .. floor(ngx.now())
    .. "_"
    .. _state.seq_counter

  _state.seq_counter = _state.seq_counter + 1

  local response, err = _post(
    _state.config.saas_url .. "/api/v1/edge/events",
    {
      edge_id = _state.config.edge_id,
      clock_skew_suspected = _state.clock_skew_suspected,
      clock_skew_seconds = _state.clock_skew_seconds,
      events = batch,
    },
    _headers({ ["Idempotency-Key"] = idempotency_key })
  )

  if err then
    _record_failure()
    _schedule_retry("event")
    _inc_events_sent("error")
    return 0
  end

  if response.status and response.status >= 400 then
    if _is_non_retriable_status(response.status) then
      _clear_retry("event")
      _log_err("_flush_once non_retriable_status ", response.status)
      _inc_events_sent("error")
      return 0
    end

    _record_failure()
    _schedule_retry("event")
    _inc_events_sent("error")
    return 0
  end

  _record_success()
  _clear_retry("event")
  _inc_events_sent("success")

  -- Slice off the flushed batch in O(n) instead of O(n * batch_size) with table.remove(_, 1).
  local buf = _state.event_buffer
  local n = #buf
  for i = 1, n - batch_size do
    buf[i] = buf[i + batch_size]
  end
  for i = n - batch_size + 1, n do
    buf[i] = nil
  end

  return batch_size
end

local function _event_flush_tick()
  _flush_once()
end

local function _reset_state(config, deps)
  _state.initialized = false
  _state.config = config
  _state.deps = deps
  _state.start_time = ngx.now()
  _state.event_buffer = {}
  _state.consecutive_failures = 0
  _state.half_open_successes = 0
  _state.circuit_state = STATE_CLOSED
  _state.opened_at = 0
  _state.seq_counter = 0
  _state.clock_skew_suspected = false
  _state.clock_skew_seconds = 0
  _state.heartbeat_attempt = 0
  _state.heartbeat_next_retry_at = 0
  _state.event_attempt = 0
  _state.event_next_retry_at = 0
  _state.config_attempt = 0
  _state.config_next_retry_at = 0
  _state.register_attempt = 0
  _state.register_next_retry_at = 0
  _state.last_config_poll_at = 0
end

local function _validate_config(config)
  if type(config) ~= "table" then
    return nil, "config must be a table"
  end

  if type(config.edge_id) ~= "string" or config.edge_id == "" then
    return nil, "edge_id is required"
  end

  if type(config.edge_token) ~= "string" or config.edge_token == "" then
    return nil, "edge_token is required"
  end

  if type(config.saas_url) ~= "string" or config.saas_url == "" then
    return nil, "saas_url is required"
  end

  if config.heartbeat_interval == nil then
    config.heartbeat_interval = DEFAULT_HEARTBEAT_INTERVAL
  end

  if config.event_flush_interval == nil then
    config.event_flush_interval = DEFAULT_EVENT_FLUSH_INTERVAL
  end

  if config.config_poll_interval == nil then
    config.config_poll_interval = DEFAULT_CONFIG_POLL_INTERVAL
  end

  if config.max_batch_size == nil then
    config.max_batch_size = DEFAULT_MAX_BATCH_SIZE
  end

  if config.max_buffer_size == nil then
    config.max_buffer_size = DEFAULT_MAX_BUFFER_SIZE
  end

  if config.http_connect_timeout == nil then
    config.http_connect_timeout = 5
  end

  if config.http_send_timeout == nil then
    config.http_send_timeout = 10
  end

  return true
end

local function _validate_deps(deps)
  if type(deps) ~= "table" then
    return nil, "deps must be a table"
  end

  if type(deps.bundle_loader) ~= "table" then
    return nil, "deps.bundle_loader is required"
  end

  if type(deps.bundle_loader.get_current) ~= "function"
      or type(deps.bundle_loader.load_from_string) ~= "function"
      or type(deps.bundle_loader.apply) ~= "function" then
    return nil, "deps.bundle_loader must implement get_current, load_from_string, and apply"
  end

  if type(deps.health) ~= "table" then
    return nil, "deps.health is required"
  end

  if type(deps.health.set) ~= "function" or type(deps.health.inc) ~= "function" then
    return nil, "deps.health must implement set and inc"
  end

  return true
end

function _M.init(config, deps)
  local ok, err = _validate_config(config)
  if not ok then
    return nil, err
  end

  ok, err = _validate_deps(deps)
  if not ok then
    return nil, err
  end

  _reset_state(config, deps)
  _set_reachable(1)

  ok, err = _register()
  if not ok then
    return nil, err or "register failed"
  end

  _state.initialized = true

  if ngx.timer and ngx.timer.every then
    ngx.timer.every(config.heartbeat_interval, function(premature)
      if premature then
        return
      end
      _heartbeat_tick()
    end)

    ngx.timer.every(config.event_flush_interval, function(premature)
      if premature then
        return
      end
      _event_flush_tick()
    end)
  end

  return true
end

function _M.queue_event(event)
  if not _state.initialized then
    return nil, "saas_client is not initialized"
  end

  if #_state.event_buffer >= _state.config.max_buffer_size then
    table_remove(_state.event_buffer, 1)
    _log_warn("queue_event event_buffer_overflow_drop_oldest ", #_state.event_buffer)
  end

  _state.event_buffer[#_state.event_buffer + 1] = event
  return true
end

function _M.flush_events()
  if not _state.initialized then
    return 0
  end

  local flushed = 0
  while #_state.event_buffer > 0 do
    local consumed = _flush_once()
    if consumed <= 0 then
      break
    end
    flushed = flushed + consumed
  end

  return flushed
end

function _M.get_state()
  if _state.circuit_state == STATE_HALF_OPEN then
    return "half_open"
  end
  if _state.circuit_state == STATE_OPEN then
    return "disconnected"
  end
  return "connected"
end

function _M.pull_config()
  if not _state.initialized then
    return nil, "saas_client is not initialized"
  end

  return _pull_config_tick()
end

return _M
