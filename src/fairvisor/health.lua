local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local type = type
local table_concat = table.concat
local table_insert = table.insert
local table_sort = table.sort

local EDGE_VERSION = require("fairvisor.version")

local _M = {}

local CANONICAL_METRICS = {
  { name = "fairvisor_decisions_total", metric_type = "counter", help = "Total decisions" },
  { name = "fairvisor_decision_duration_seconds", metric_type = "gauge", help = "Decision latency seconds" },
  { name = "fairvisor_ratelimit_remaining", metric_type = "gauge", help = "Remaining rate limit budget" },
  { name = "fairvisor_tokens_consumed_total", metric_type = "counter", help = "Total token usage reservations/actuals" },
  { name = "fairvisor_tokens_remaining", metric_type = "gauge", help = "Remaining token budget by window" },
  { name = "fairvisor_token_estimation_accuracy_ratio", metric_type = "gauge", help = "Token estimation ratio actual/estimated" },
  { name = "fairvisor_token_reservation_unused_total", metric_type = "counter", help = "Unused reserved tokens refunded" },
  { name = "fairvisor_loop_detected_total", metric_type = "counter", help = "Loop detections" },
  { name = "fairvisor_circuit_state", metric_type = "gauge", help = "Circuit state (0 closed, 1 open, 0.5 half_open)" },
  { name = "fairvisor_kill_switch_active", metric_type = "gauge", help = "Kill switch active flag" },
  { name = "fairvisor_shadow_mode_active", metric_type = "gauge", help = "Shadow mode active flag" },
  { name = "fairvisor_global_shadow_active", metric_type = "gauge", help = "Global shadow runtime override active flag" },
  { name = "fairvisor_kill_switch_override_active", metric_type = "gauge", help = "Kill switch override runtime flag" },
  { name = "fairvisor_saas_reachable", metric_type = "gauge", help = "SaaS reachability (1 reachable, 0 unreachable)" },
  { name = "fairvisor_saas_calls_total", metric_type = "counter", help = "SaaS API calls by operation/status" },
  { name = "fairvisor_events_sent_total", metric_type = "counter", help = "Events export outcomes" },
  { name = "fairvisor_config_info", metric_type = "gauge", help = "Config info metric (always 1 for active config labels)" },
  { name = "fairvisor_build_info", metric_type = "gauge", help = "Build info metric (always 1 for active version labels)" },
}

local function _escape_label_value(value)
  local escaped = tostring(value)
  escaped = escaped:gsub("\\", "\\\\")
  escaped = escaped:gsub('"', '\\"')
  escaped = escaped:gsub("\n", "\\n")
  return escaped
end

local function _serialize_labels(labels)
  if type(labels) ~= "table" then
    return ""
  end

  local keys = {}
  for key, _ in pairs(labels) do
    keys[#keys + 1] = key
  end

  if #keys == 0 then
    return ""
  end

  table_sort(keys)

  local parts = {}
  for _, key in ipairs(keys) do
    local value = labels[key]
    parts[#parts + 1] = key .. '="' .. _escape_label_value(value) .. '"'
  end

  return "{" .. table_concat(parts, ",") .. "}"
end

local function _sorted_keys(map)
  local keys = {}
  for key, _ in pairs(map) do
    keys[#keys + 1] = key
  end
  table_sort(keys)
  return keys
end

local function _resolve_edge_version(opts)
  if type(opts) == "table" and opts.edge_version ~= nil then
    return tostring(opts.edge_version)
  end
  return EDGE_VERSION
end

local function _livez(self)
  return {
    status = "healthy",
    version = self.edge_version,
  }
end

local function _readyz(self)
  if not self.bundle_loaded then
    return nil, {
      status = "not_ready",
      reason = "no_policy_loaded",
    }
  end

  return {
    status = "ready",
    policy_version = self.bundle_version,
    policy_hash = self.bundle_hash,
    last_config_update = self.last_config_update,
  }
end

local function _set_bundle_state(self, version, hash, timestamp)
  self.bundle_loaded = true
  self.bundle_version = version
  self.bundle_hash = hash
  self.last_config_update = timestamp
  self:set("fairvisor_config_info", {
    version = tostring(version or ""),
    hash = tostring(hash or ""),
  }, 1)
end

local function _set_shutting_down(self)
  self.shutting_down = true
end

local function _register(self, name, metric_type, help)
  if self.metrics[name] ~= nil then
    return nil, "metric already registered"
  end

  if metric_type ~= "counter" and metric_type ~= "gauge" then
    return nil, "unsupported metric type"
  end

  self.metrics[name] = {
    type = metric_type,
    help = help or "",
    values = {},
  }

  return true
end

local function _inc(self, name, labels, value)
  local metric = self.metrics[name]
  if metric == nil then
    -- Lazy-create counters so call sites do not need explicit registration.
    metric = {
      type = "counter",
      help = "",
      values = {},
    }
    self.metrics[name] = metric
  end

  local key = _serialize_labels(labels)
  local amount = value
  if amount == nil then
    amount = 1
  end

  local current = metric.values[key]
  if current == nil then
    current = 0
  end
  metric.values[key] = current + amount
end

local function _set(self, name, labels, value)
  local metric = self.metrics[name]
  if metric == nil then
    -- Lazy-create gauges so call sites can set health/runtime values directly.
    metric = {
      type = "gauge",
      help = "",
      values = {},
    }
    self.metrics[name] = metric
  end

  local key = _serialize_labels(labels)
  metric.values[key] = value
end

local function _render(self)
  local lines = {}

  local metric_names = _sorted_keys(self.metrics)
  for _, name in ipairs(metric_names) do
    local metric = self.metrics[name]
    table_insert(lines, "# HELP " .. name .. " " .. metric.help)
    table_insert(lines, "# TYPE " .. name .. " " .. metric.type)

    local series_keys = _sorted_keys(metric.values)
    for _, label_key in ipairs(series_keys) do
      local line = name .. label_key .. " " .. tostring(metric.values[label_key])
      table_insert(lines, line)
    end
  end

  return table_concat(lines, "\n")
end

local _health_methods = {
  livez = _livez,
  readyz = _readyz,
  set_bundle_state = _set_bundle_state,
  set_shutting_down = _set_shutting_down,
  register = _register,
  inc = _inc,
  set = _set,
  render = _render,
}

local function _register_canonical_metrics(instance)
  for i = 1, #CANONICAL_METRICS do
    local def = CANONICAL_METRICS[i]
    instance:register(def.name, def.metric_type, def.help)
  end
  instance:set("fairvisor_build_info", {
    version = tostring(instance.edge_version),
  }, 1)
end

function _M.new(opts)
  local instance = {
    bundle_loaded = false,
    shutting_down = false,
    bundle_version = nil,
    bundle_hash = nil,
    last_config_update = nil,
    edge_version = _resolve_edge_version(opts),
    metrics = {},
  }
  setmetatable(instance, { __index = _health_methods })
  _register_canonical_metrics(instance)
  return instance
end

-- Default instance for module-level API used by bundle_loader and other callers that do not hold an instance.
local _default_instance

local function _get_default()
  if _default_instance == nil then
    _default_instance = _M.new(nil)
  end
  return _default_instance
end

--- Module-level set_bundle_state for compatibility with bundle_loader. Delegates to the default instance.
function _M.set_bundle_state(version, hash, loaded_at)
  _get_default():set_bundle_state(version, hash, loaded_at)
end

--- Module-level get_bundle_state for compatibility. Returns { version, hash, loaded_at } from the default instance.
function _M.get_bundle_state()
  local inst = _get_default()
  return {
    version = inst.bundle_version,
    hash = inst.bundle_hash,
    loaded_at = inst.last_config_update,
  }
end

function _M.livez()
  return _get_default():livez()
end

function _M.readyz()
  return _get_default():readyz()
end

function _M.set_shutting_down()
  return _get_default():set_shutting_down()
end

function _M.register(a, b, c, d)
  local name, metric_type, help
  if type(a) == "table" then
    name, metric_type, help = b, c, d
  else
    name, metric_type, help = a, b, c
  end
  return _get_default():register(name, metric_type, help)
end

function _M.inc(a, b, c, d)
  local name, labels, value
  if type(a) == "table" then
    name, labels, value = b, c, d
  else
    name, labels, value = a, b, c
  end
  return _get_default():inc(name, labels, value)
end

function _M.set(a, b, c, d)
  local name, labels, value
  if type(a) == "table" then
    name, labels, value = b, c, d
  else
    name, labels, value = a, b, c
  end
  return _get_default():set(name, labels, value)
end

function _M.render(_maybe_self)
  return _get_default():render()
end

return _M
