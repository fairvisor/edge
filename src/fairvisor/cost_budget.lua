local ceil = math.ceil
local floor = math.floor
local max = math.max
local sort = table.sort
local tonumber = tonumber
local type = type
local string_find = string.find
local string_sub = string.sub

local KEY_PREFIX = "cb:"

local PERIOD_SECONDS = {
  ["5m"] = 300,
  ["1h"] = 3600,
  ["1d"] = 86400,
  ["7d"] = 604800,
}

local _M = {}

local function _is_valid_source_name(name)
  if type(name) ~= "string" or name == "" then
    return false
  end

  return string_find(name, "^[%w_-]+$") ~= nil
end

local function _parse_cost_key(cost_key)
  if cost_key == "fixed" then
    return "fixed", nil
  end

  if string_sub(cost_key, 1, 7) == "header:" then
    local name = string_sub(cost_key, 8)
    if _is_valid_source_name(name) then
      return "header", name
    end
    return nil, nil
  end

  if string_sub(cost_key, 1, 6) == "query:" then
    local name = string_sub(cost_key, 7)
    if _is_valid_source_name(name) then
      return "query", name
    end
    return nil, nil
  end

  return nil, nil
end

-- Expects staged_actions sorted by threshold_percent ascending; returns the highest applicable action.
local function _evaluate_staged_actions(staged_actions, usage_percent)
  local selected

  for i = 1, #staged_actions do
    local action = staged_actions[i]
    if usage_percent >= action.threshold_percent then
      selected = action
    end
  end

  return selected
end

local function _compute_retry_after(period, period_start, now)
  local period_seconds = PERIOD_SECONDS[period]
  local next_period = period_start + period_seconds
  local retry_after = ceil(next_period - now)
  if retry_after < 1 then
    retry_after = 1
  end
  return retry_after
end

function _M.compute_period_start(period, now)
  if type(now) ~= "number" then
    return nil, "now must be a number"
  end

  if period == "1h" then
    return floor(now / 3600) * 3600
  end

  if period == "5m" then
    return floor(now / 300) * 300
  end

  if period == "1d" then
    return floor(now / 86400) * 86400
  end

  if period == "7d" then
    return floor((now - 259200) / 604800) * 604800 + 259200
  end

  return nil, "unknown period"
end

function _M.validate_config(config)
  if type(config) ~= "table" then
    return nil, "config must be a table"
  end

  if config.algorithm ~= "cost_based" then
    return nil, "algorithm must be cost_based"
  end

  if type(config.budget) ~= "number" or config.budget <= 0 then
    return nil, "budget must be a positive number"
  end

  if PERIOD_SECONDS[config.period] == nil then
    return nil, "period must be one of 5m, 1h, 1d, 7d"
  end

  if config.cost_key == nil then
    config.cost_key = "fixed"
  end

  if type(config.cost_key) ~= "string" then
    return nil, "cost_key must be fixed, header:<name>, or query:<name>"
  end

  local cost_key_kind, cost_key_name = _parse_cost_key(config.cost_key)
  if not cost_key_kind then
    return nil, "cost_key must be fixed, header:<name>, or query:<name>"
  end
  config._cost_key_kind = cost_key_kind
  config._cost_key_name = cost_key_name

  if config.default_cost == nil then
    config.default_cost = 1
  end

  if type(config.default_cost) ~= "number" or config.default_cost <= 0 then
    return nil, "default_cost must be a positive number"
  end

  if config.fixed_cost == nil then
    config.fixed_cost = 1
  end

  if cost_key_kind == "fixed" and (type(config.fixed_cost) ~= "number" or config.fixed_cost <= 0) then
    return nil, "fixed_cost must be a positive number"
  end

  if type(config.staged_actions) ~= "table" or #config.staged_actions == 0 then
    return nil, "staged_actions must be a non-empty table"
  end

  for i = 1, #config.staged_actions do
    local staged_action = config.staged_actions[i]

    if type(staged_action) ~= "table" then
      return nil, "staged_action must be a table"
    end

    if type(staged_action.threshold_percent) ~= "number"
        or staged_action.threshold_percent < 0
        or staged_action.threshold_percent > 100 then
      return nil, "threshold_percent must be between 0 and 100"
    end

    if staged_action.action ~= "warn" and staged_action.action ~= "throttle" and staged_action.action ~= "reject" then
      return nil, "action must be one of warn, throttle, reject"
    end

    if staged_action.action == "throttle" and (type(staged_action.delay_ms) ~= "number" or staged_action.delay_ms <= 0) then
      return nil, "delay_ms must be a positive number for throttle action"
    end
  end

  sort(config.staged_actions, function(left, right)
    return left.threshold_percent < right.threshold_percent
  end)

  local last_threshold = nil
  local has_reject_at_100 = false

  for i = 1, #config.staged_actions do
    local staged_action = config.staged_actions[i]

    if last_threshold ~= nil and staged_action.threshold_percent <= last_threshold then
      return nil, "staged_actions thresholds must be strictly ascending"
    end

    if staged_action.action == "reject" and staged_action.threshold_percent == 100 then
      has_reject_at_100 = true
    end

    last_threshold = staged_action.threshold_percent
  end

  if not has_reject_at_100 then
    return nil, "staged_actions must include reject at 100%"
  end

  return true
end

function _M.build_key(rule_name, limit_key_value)
  return KEY_PREFIX .. rule_name .. ":" .. (limit_key_value or "")
end

-- Config should be validated first so _cost_key_kind and _cost_key_name are set; falls back to parsing
-- cost_key when they are missing (e.g. resolve_cost called without validate_config).
function _M.resolve_cost(config, request_context)
  local default_cost = config.default_cost or 1
  local cost_key_kind = config._cost_key_kind
  local cost_key_name = config._cost_key_name

  if not cost_key_kind then
    local cost_key = config.cost_key or "fixed"
    if cost_key == "fixed" then
      local fixed_cost = config.fixed_cost or default_cost
      if fixed_cost <= 0 then
        return default_cost
      end
      return fixed_cost
    end

    cost_key_kind, cost_key_name = _parse_cost_key(cost_key)
    if not cost_key_kind then
      return default_cost
    end
  end

  if cost_key_kind == "fixed" then
    local fixed_cost = config.fixed_cost or default_cost
    if fixed_cost <= 0 then
      return default_cost
    end
    return fixed_cost
  end

  local value
  if cost_key_kind == "header" then
    local headers = request_context and request_context.headers
    value = headers and headers[cost_key_name]
  else
    local query_params = request_context and request_context.query_params
    value = query_params and query_params[cost_key_name]
  end

  local cost = tonumber(value)
  if not cost or cost <= 0 then
    return default_cost
  end

  return cost
end

function _M.check(dict, key, config, cost, now)
  if cost == nil or cost <= 0 then
    cost = config.default_cost or 1
    if cost <= 0 then
      cost = 1
    end
  end

  local current_now = now
  if current_now == nil then
    current_now = ngx.now()
  end

  local period_start = _M.compute_period_start(config.period, current_now)
  if period_start == nil then
    period_start = floor(current_now)
  end

  local full_key = key .. ":" .. period_start

  local new_usage, err = dict:incr(full_key, cost, 0)
  if not new_usage then
    -- Fail-open: allow request but set error so caller can log (e.g. descriptor_missing / dict unavailable).
    return {
      allowed = true,
      action = "allow",
      budget_remaining = config.budget,
      usage_percent = 0,
      warning = nil,
      delay_ms = nil,
      reason = nil,
      retry_after = nil,
      error = err,
    }
  end

  local budget_remaining = max(0, config.budget - new_usage)
  local usage_percent = (new_usage / config.budget) * 100
  local over_budget = new_usage > config.budget
  local staged_action = _evaluate_staged_actions(config.staged_actions, usage_percent)

  if not over_budget and staged_action ~= nil and staged_action.action == "reject" then
    staged_action = nil
    for i = 1, #config.staged_actions do
      local action = config.staged_actions[i]
      if action.action ~= "reject" and usage_percent >= action.threshold_percent then
        staged_action = action
      end
    end
  end

  if not over_budget and (staged_action == nil or staged_action.action == "allow") then
    return {
      allowed = true,
      action = "allow",
      budget_remaining = budget_remaining,
      usage_percent = usage_percent,
      warning = nil,
      delay_ms = nil,
      reason = nil,
      retry_after = nil,
      error = nil,
    }
  end

  if not over_budget and staged_action.action == "warn" then
    return {
      allowed = true,
      action = "warn",
      budget_remaining = budget_remaining,
      usage_percent = usage_percent,
      warning = true,
      delay_ms = nil,
      reason = nil,
      retry_after = nil,
      error = nil,
    }
  end

  if not over_budget and staged_action.action == "throttle" then
    return {
      allowed = true,
      action = "throttle",
      budget_remaining = budget_remaining,
      usage_percent = usage_percent,
      warning = nil,
      delay_ms = staged_action.delay_ms,
      reason = nil,
      retry_after = nil,
      error = nil,
    }
  end

  -- Roll back so the rejected request is not charged; usage stays at pre-request level.
  dict:incr(full_key, -cost)

  return {
    allowed = false,
    action = "reject",
    budget_remaining = 0,
    usage_percent = usage_percent,
    warning = nil,
    delay_ms = nil,
    reason = "budget_exceeded",
    retry_after = _compute_retry_after(config.period, period_start, current_now),
    error = nil,
  }
end

return _M
