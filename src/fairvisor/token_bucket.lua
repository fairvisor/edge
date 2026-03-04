local ceil = math.ceil
local floor = math.floor
local max = math.max
local min = math.min
local tonumber = tonumber
local type = type
local string_find = string.find
local string_format = string.format
local string_sub = string.sub

local KEY_PREFIX = "tb:"

local _M = {}

local function _is_valid_source_name(name)
  if type(name) ~= "string" or name == "" then
    return false
  end

  return string_find(name, "^[%w_-]+$") ~= nil
end

local function _parse_cost_source(source)
  if source == "fixed" then
    return "fixed", nil
  end

  if string_sub(source, 1, 7) == "header:" then
    local name = string_sub(source, 8)
    if _is_valid_source_name(name) then
      return "header", name
    end
    return nil, nil
  end

  if string_sub(source, 1, 6) == "query:" then
    local name = string_sub(source, 7)
    if _is_valid_source_name(name) then
      return "query", name
    end
    return nil, nil
  end

  return nil, nil
end

-- Format required by brief §3; single hot-path allocation accepted per spec.
local function _serialize(tokens, last_refill)
  return string_format("%.6f:%.6f", tokens, last_refill)
end

local function _deserialize(raw)
  local sep = string_find(raw, ":", 1, true)
  if not sep then
    return nil, nil
  end

  local tokens = tonumber(string_sub(raw, 1, sep - 1))
  local last_refill = tonumber(string_sub(raw, sep + 1))

  if not tokens or not last_refill then
    return nil, nil
  end

  return tokens, last_refill
end

local function _validate_positive_number(config, field)
  local value = config[field]
  if value == nil then
    return nil, field .. " is required"
  end

  if type(value) ~= "number" or value <= 0 then
    return nil, field .. " must be a positive number"
  end

  return true
end

-- Normalizes and fills defaults in config for request-time use (mutates in place).
function _M.validate_config(config)
  if type(config) ~= "table" then
    return nil, "config must be a table"
  end

  if config.algorithm ~= "token_bucket" then
    return nil, "algorithm must be token_bucket"
  end

  if config.tokens_per_second == nil then
    if config.rps == nil then
      return nil, "tokens_per_second or rps is required"
    end
    config.tokens_per_second = config.rps
  end

  local ok, err = _validate_positive_number(config, "tokens_per_second")
  if not ok then
    return nil, err
  end

  ok, err = _validate_positive_number(config, "burst")
  if not ok then
    return nil, err
  end

  if config.burst < config.tokens_per_second then
    return nil, "burst must be >= tokens_per_second"
  end

  if config.cost_source == nil then
    config.cost_source = "fixed"
  end

  if type(config.cost_source) ~= "string" then
    return nil, "cost_source must be fixed, header:<name>, or query:<name>"
  end

  local source_kind, source_name = _parse_cost_source(config.cost_source)
  if not source_kind then
    return nil, "cost_source must be fixed, header:<name>, or query:<name>"
  end
  config._cost_source_kind = source_kind
  config._cost_source_name = source_name

  if config.fixed_cost == nil then
    config.fixed_cost = 1
  end

  if type(config.fixed_cost) ~= "number" or config.fixed_cost <= 0 then
    return nil, "fixed_cost must be a positive number"
  end

  if config.default_cost == nil then
    config.default_cost = 1
  end

  if type(config.default_cost) ~= "number" or config.default_cost <= 0 then
    return nil, "default_cost must be a positive number"
  end

  return true
end

function _M.build_key(rule_name, limit_key_value)
  return KEY_PREFIX .. rule_name .. ":" .. (limit_key_value or "")
end

function _M.resolve_cost(config, request_context)
  local default_cost = config.default_cost or 1
  local source_kind = config._cost_source_kind
  local source_name = config._cost_source_name
  if not source_kind then
    local source = config.cost_source or "fixed"
    if source == "fixed" then
      local fixed_cost = config.fixed_cost or default_cost
      if fixed_cost <= 0 then
        return 1
      end
      return fixed_cost
    end
    source_kind, source_name = _parse_cost_source(source)
    if not source_kind then
      return default_cost
    end
  end

  if source_kind == "fixed" then
    local fixed_cost = config.fixed_cost or default_cost
    if fixed_cost <= 0 then
      return 1
    end
    return fixed_cost
  end

  local value
  if source_kind == "header" then
    local headers = request_context and request_context.headers
    value = headers and headers[source_name]
  else
    local query_params = request_context and request_context.query_params
    value = query_params and query_params[source_name]
  end

  local cost = tonumber(value)
  if not cost or cost <= 0 then
    return default_cost
  end

  return cost
end

-- Refill then consume; state in one key. At most 1 get + 1 set per call (Article II.2.1.3). See brief §3.
function _M.check(dict, key, config, cost)
  local now = ngx.now()
  local raw = dict:get(key)

  local tokens = config.burst
  local last_refill = now

  if raw ~= nil then
    local parsed_tokens, parsed_last_refill = _deserialize(raw)
    if parsed_tokens and parsed_last_refill then
      tokens = parsed_tokens
      last_refill = parsed_last_refill
    end
  end

  local elapsed = max(0, now - last_refill)
  tokens = min(tokens + elapsed * config.tokens_per_second, config.burst)

  if cost == nil or cost <= 0 then
    cost = 1
  end

  if tokens >= cost then
    tokens = tokens - cost
    dict:set(key, _serialize(tokens, now))
    return {
      allowed = true,
      remaining = floor(tokens),
      limit = config.burst,
      retry_after = nil,
    }
  end

  dict:set(key, _serialize(tokens, now))

  local retry_after = ceil((cost - tokens) / config.tokens_per_second)
  if retry_after < 1 then
    retry_after = 1
  end

  return {
    allowed = false,
    remaining = 0,
    retry_after = retry_after,
    limit = config.burst,
  }
end

return _M
