local pairs = pairs
local pcall = pcall
local tostring = tostring
local type = type

local string_find = string.find
local string_gsub = string.gsub
local string_lower = string.lower
local string_sub = string.sub
local table_concat = table.concat

-- OpenResty ngx.req.get_headers() normalizes names to lowercase and replaces hyphen with underscore.
-- Normalize so that "x-e2e-key" (from limit_key) matches "x_e2e_key" (from get_headers).
local function _normalize_header_name(s)
  if type(s) ~= "string" then
    return ""
  end
  return string_gsub(string_lower(s), "-", "_")
end

local GENERATED_AUTOMATON_MODULE = "fairvisor.generated.bot_automaton"
local LEGACY_BOT_PATTERNS = {
  { pattern = "GPTBot", category = "ai_crawler" },
  { pattern = "ChatGPT-User", category = "ai_assistant_user" },
  { pattern = "OAI-SearchBot", category = "ai_crawler" },
  { pattern = "ClaudeBot", category = "ai_crawler" },
  { pattern = "Claude-Web", category = "ai_assistant_user" },
  { pattern = "Meta-ExternalAgent", category = "ai_crawler" },
  { pattern = "Meta-ExternalFetcher", category = "ai_crawler" },
  { pattern = "Google-Extended", category = "ai_crawler" },
  { pattern = "Googlebot", category = "search_engine" },
  { pattern = "Bingbot", category = "search_engine" },
  { pattern = "Amazonbot", category = "other_bot" },
  { pattern = "Bytespider", category = "ai_crawler" },
  { pattern = "CCBot", category = "ai_crawler" },
  { pattern = "anthropic-ai", category = "ai_crawler" },
  { pattern = "Applebot-Extended", category = "search_engine" },
}

local _M = {}

local _generated_bot_automaton = nil

local function _get_first_value(value)
  if type(value) == "table" then
    return value[1]
  end
  return value
end

function _M.parse_key(key)
  if type(key) ~= "string" then
    return nil, nil
  end

  local colon = string_find(key, ":", 1, true)
  if not colon or colon <= 1 then
    return nil, nil
  end

  local source = string_sub(key, 1, colon - 1)
  local name = string_sub(key, colon + 1)
  if name == "" then
    return nil, nil
  end

  return source, name
end

local function _is_valid_limit_key(key)
  local source, name = _M.parse_key(key)
  if not source then
    return false
  end

  -- Header/query/jwt name: alphanumeric, underscore, hyphen only (no colon).
  if source == "jwt" or source == "header" or source == "query" then
    return string_find(name, "^[A-Za-z0-9_-]+$") ~= nil
  end

  if source == "ip" then
    return name == "address" or name == "country" or name == "asn" or name == "type" or name == "tor"
  end

  if source == "ua" then
    return name == "bot" or name == "bot_category"
  end

  return false
end

function _M.validate_limit_keys(limit_keys)
  if type(limit_keys) ~= "table" then
    return nil, "limit_keys must be a table"
  end

  for i = 1, #limit_keys do
    local key = limit_keys[i]
    if type(key) ~= "string" or not _is_valid_limit_key(key) then
      return nil, "invalid limit_key format: " .. tostring(key)
    end
  end

  return true
end

function _M.build_bot_index(patterns)
  local index = {
    patterns = {},
  }

  if type(patterns) ~= "table" or #patterns == 0 then
    for i = 1, #LEGACY_BOT_PATTERNS do
      index.patterns[#index.patterns + 1] = {
        pattern = string_lower(LEGACY_BOT_PATTERNS[i].pattern),
        category = LEGACY_BOT_PATTERNS[i].category,
      }
    end
    return index
  end

  for i = 1, #patterns do
    local pattern = patterns[i]
    if type(pattern) == "string" and pattern ~= "" then
      index.patterns[#index.patterns + 1] = {
        pattern = string_lower(pattern),
        category = "other_bot",
      }
    end
  end

  return index
end

local function _load_generated_automaton()
  if _generated_bot_automaton ~= nil then
    return _generated_bot_automaton
  end

  local ok, module = pcall(require, GENERATED_AUTOMATON_MODULE)
  if ok and module and type(module.match) == "function" then
    _generated_bot_automaton = module
    return _generated_bot_automaton
  end

  _generated_bot_automaton = false
  return _generated_bot_automaton
end

function _M.classify_bot(bot_index_or_ua, maybe_user_agent)
  local explicit_index = nil
  local user_agent = bot_index_or_ua

  -- Backward compatible signature: classify_bot(index, user_agent) -> "true"/"false"|nil.
  if type(bot_index_or_ua) == "table" then
    explicit_index = bot_index_or_ua
    user_agent = maybe_user_agent
  end

  if user_agent == nil or user_agent == "" then
    return nil
  end

  if type(explicit_index) == "table" and type(explicit_index.patterns) == "table" then
    local ua_lower = string_lower(user_agent)
    local best_len = 0
    for i = 1, #explicit_index.patterns do
      local pattern = explicit_index.patterns[i] and explicit_index.patterns[i].pattern
      if pattern and string_find(ua_lower, pattern, 1, true) ~= nil and #pattern > best_len then
        best_len = #pattern
      end
    end
    if best_len > 0 then
      return "true"
    end
    return "false"
  end

  local automaton = _load_generated_automaton()
  if automaton and automaton ~= false then
    local matched = automaton.match(user_agent)
    if matched ~= nil then
      return {
        bot = "true",
        category = tostring(matched.category or "other_bot"),
      }
    end
  end

  local ua_lower = string_lower(user_agent)
  local best = nil
  for i = 1, #LEGACY_BOT_PATTERNS do
    local p = LEGACY_BOT_PATTERNS[i]
    local lowered = string_lower(p.pattern)
    local start_idx = string_find(ua_lower, lowered, 1, true)
    if start_idx ~= nil then
      if best == nil or #lowered > #best.pattern then
        best = { pattern = lowered, category = p.category }
      end
    end
  end

  if best ~= nil then
    return {
      bot = "true",
      category = best.category or "other_bot",
    }
  end

  return {
    bot = "false",
    category = nil,
  }
end

--[[
  request_context (table): expected fields when extracting descriptors.
  - jwt_claims (table): claim name -> value (e.g. org_id = "acme").
  - headers (table): header name -> value or { value1, value2 }; first value is used.
  - query_params (table): param name -> value or { value1, value2 }; first value is used.
  - ip_address (string): client IP.
  - ip_country (string): country code from GeoIP.
  - ip_asn (string): ASN from GeoIP.
  - ip_tor (string|boolean): "true"/"false" or bool for Tor exit classification.
  - user_agent (string): User-Agent header for ua:bot.
  Header lookup is case-insensitive; jwt/query keys are used as-is.
]]
function _M.extract(limit_keys, request_context)
  local descriptors = {}
  local missing_keys = {}

  if type(limit_keys) ~= "table" then
    return descriptors, missing_keys
  end

  for i = 1, #limit_keys do
    local key = limit_keys[i]
    local source, name = _M.parse_key(key)
    local value = nil

    if source == "jwt" then
      local jwt_claims = request_context and request_context.jwt_claims
      value = jwt_claims and jwt_claims[name]
    elseif source == "header" then
      local headers = request_context and request_context.headers
      if headers then
        value = headers[name]
        if value == nil then
          -- OpenResty normalizes header names: lowercase and hyphen to underscore (e.g. X-E2E-Key -> x_e2e_key).
          local name_underscore = string_gsub(name, "-", "_")
          local name_lower = string_lower(name)
          value = headers[name_underscore] or headers[name_lower]
        end
        if value == nil then
          local name_norm = _normalize_header_name(name)
          for hk, hv in pairs(headers) do
            if _normalize_header_name(hk) == name_norm then
              value = hv
              break
            end
          end
        end
        value = _get_first_value(value)
      end
    elseif source == "query" then
      local query_params = request_context and request_context.query_params
      value = _get_first_value(query_params and query_params[name])
    elseif source == "ip" then
      if name == "address" then
        value = request_context and request_context.ip_address
      elseif name == "country" then
        value = request_context and request_context.ip_country
      elseif name == "asn" then
        value = request_context and request_context.ip_asn
      elseif name == "type" then
        value = request_context and request_context.ip_type
      elseif name == "tor" then
        value = request_context and request_context.ip_tor
      end
    elseif source == "ua" and (name == "bot" or name == "bot_category") then
      if request_context then
        if request_context._bot_cache == nil then
          request_context._bot_cache = _M.classify_bot(request_context.user_agent) or false
        end

        if request_context._bot_cache ~= false then
          if name == "bot" then
            value = request_context._bot_cache.bot
          else
            value = request_context._bot_cache.category
          end
        end
      end
    end

    if value == nil or value == "" then
      missing_keys[#missing_keys + 1] = key
    else
      descriptors[key] = tostring(value)
    end
  end

  return descriptors, missing_keys
end

function _M.build_composite_key(limit_keys, descriptors)
  local parts = {}

  for i = 1, #limit_keys do
    local key = limit_keys[i]
    local value = descriptors and descriptors[key]
    if value == nil then
      parts[i] = ""
    else
      parts[i] = tostring(value)
    end
  end

  return table_concat(parts, "|")
end
return _M
