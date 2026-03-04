-- Shared utilities. Used by bundle_loader, kill_switch, decision_api, etc.
-- Provides: base64/base64url, constant-time compare, now(), safe_require,
-- JSON chain (get_json), ISO 8601 parsing.

local floor = math.floor
local os_date = os.date
local os_difftime = os.difftime
local os_time = os.time
local pairs = pairs
local pcall = pcall
local string_byte = string.byte
local string_char = string.char
local string_find = string.find
local string_match = string.match
local string_gsub = string.gsub
local string_sub = string.sub
local table_concat = table.concat
local tonumber = tonumber
local tostring = tostring
local type = type

local bit
do
  local ok, b = pcall(require, "bit")
  if ok and b then
    bit = b
  end
end

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local _M = {}

--- Current time (epoch seconds). Uses ngx.now() when available, else 0.
function _M.now()
  if ngx and ngx.now then
    return ngx.now()
  end
  return 0
end

--- Safe require: returns module or nil (no throw).
function _M.safe_require(name)
  local ok, mod = pcall(require, name)
  if ok and mod then
    return mod
  end
  return nil
end

--- Constant-time string comparison (for signatures/tokens). Uses bit when available.
function _M.constant_time_equals(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then
    return false
  end
  if not bit then
    return a == b
  end
  local len_a = #a
  local len_b = #b
  local max_len = len_a
  if len_b > max_len then
    max_len = len_b
  end
  local diff = bit.bxor(len_a, len_b)
  for i = 1, max_len do
    local byte_a = string_byte(a, i) or 0
    local byte_b = string_byte(b, i) or 0
    diff = bit.bor(diff, bit.bxor(byte_a, byte_b))
  end
  return diff == 0
end

local function _decode_base64_fallback(input)
  local cleaned = string_gsub(input, "=+$", "")
  local bytes = {}
  local bit_buffer = 0
  local bit_count = 0
  for i = 1, #cleaned do
    local char = string_sub(cleaned, i, i)
    local index = string_find(BASE64_ALPHABET, char, 1, true)
    if not index then
      return nil
    end
    bit_buffer = bit_buffer * 64 + (index - 1)
    bit_count = bit_count + 6
    while bit_count >= 8 do
      bit_count = bit_count - 8
      local value = floor(bit_buffer / (2 ^ bit_count)) % 256
      bytes[#bytes + 1] = string_char(value)
    end
  end
  return table_concat(bytes)
end

--- Decode base64 string. Uses ngx.decode_base64 when available.
function _M.decode_base64(input)
  if ngx and ngx.decode_base64 then
    return ngx.decode_base64(input)
  end
  return _decode_base64_fallback(input)
end

--- Decode base64url string (JWT-style: - and _).
function _M.base64url_decode(input)
  if type(input) ~= "string" or input == "" then
    return nil
  end
  local normalized = string_gsub(input, "-", "+")
  normalized = string_gsub(normalized, "_", "/")
  local remainder = #normalized % 4
  if remainder == 2 then
    normalized = normalized .. "=="
  elseif remainder == 3 then
    normalized = normalized .. "="
  elseif remainder == 1 then
    return nil
  end
  return _M.decode_base64(normalized)
end

--- Encode raw bytes to base64. Uses ngx.encode_base64 when available; else returns nil.
function _M.encode_base64(raw)
  if ngx and ngx.encode_base64 then
    return ngx.encode_base64(raw)
  end
  return nil
end

-- Inlined JSON encoder/decoder (no unicode escapes in strings).
local function _json_is_array(value)
  if type(value) ~= "table" then
    return false
  end
  local max_index = 0
  local count = 0
  for k, _ in pairs(value) do
    if type(k) ~= "number" or k < 1 or k ~= floor(k) then
      return false
    end
    if k > max_index then
      max_index = k
    end
    count = count + 1
  end
  return max_index == count
end

local function _json_escape_string(value)
  local escaped = value
  escaped = string_gsub(escaped, "\\", "\\\\")
  escaped = string_gsub(escaped, '"', '\\"')
  escaped = string_gsub(escaped, "\b", "\\b")
  escaped = string_gsub(escaped, "\f", "\\f")
  escaped = string_gsub(escaped, "\n", "\\n")
  escaped = string_gsub(escaped, "\r", "\\r")
  escaped = string_gsub(escaped, "\t", "\\t")
  return escaped
end

local function _json_encode_value(value)
  local value_type = type(value)
  if value_type == "nil" then
    return "null"
  end
  if value_type == "boolean" then
    return value and "true" or "false"
  end
  if value_type == "number" then
    return tostring(value)
  end
  if value_type == "string" then
    return '"' .. _json_escape_string(value) .. '"'
  end
  if value_type ~= "table" then
    return nil, "unsupported value type"
  end
  if _json_is_array(value) then
    local parts = {}
    for i = 1, #value do
      local encoded_item, item_err = _json_encode_value(value[i])
      if not encoded_item then
        return nil, item_err
      end
      parts[#parts + 1] = encoded_item
    end
    return "[" .. table_concat(parts, ",") .. "]"
  end
  local parts = {}
  for key, item in pairs(value) do
    if type(key) ~= "string" then
      return nil, "object keys must be strings"
    end
    local encoded_item, item_err = _json_encode_value(item)
    if not encoded_item then
      return nil, item_err
    end
    parts[#parts + 1] = '"' .. _json_escape_string(key) .. '":' .. encoded_item
  end
  return "{" .. table_concat(parts, ",") .. "}"
end

local function _json_is_space(ch)
  return ch == " " or ch == "\t" or ch == "\n" or ch == "\r"
end

local function _json_skip_spaces(text, idx)
  while idx <= #text and _json_is_space(string_sub(text, idx, idx)) do
    idx = idx + 1
  end
  return idx
end

local function _json_decode_error(message, idx)
  return nil, message .. " at position " .. tostring(idx)
end

local _json_decode_value

local function _json_decode_string(text, idx)
  idx = idx + 1
  local out = {}
  while idx <= #text do
    local ch = string_sub(text, idx, idx)
    if ch == '"' then
      return table_concat(out), idx + 1
    end
    if ch == "\\" then
      local esc = string_sub(text, idx + 1, idx + 1)
      if esc == '"' or esc == "\\" or esc == "/" then
        out[#out + 1] = esc
      elseif esc == "b" then
        out[#out + 1] = "\b"
      elseif esc == "f" then
        out[#out + 1] = "\f"
      elseif esc == "n" then
        out[#out + 1] = "\n"
      elseif esc == "r" then
        out[#out + 1] = "\r"
      elseif esc == "t" then
        out[#out + 1] = "\t"
      elseif esc == "u" then
        return _json_decode_error("unicode escapes are not supported", idx)
      else
        return _json_decode_error("invalid escape sequence", idx)
      end
      idx = idx + 2
    else
      out[#out + 1] = ch
      idx = idx + 1
    end
  end
  return _json_decode_error("unterminated string", idx)
end

local function _json_decode_number(text, idx)
  local rest = string_sub(text, idx)
  local number_text = string_match(rest, "^-?%d+%.?%d*[eE]?[+-]?%d*")
  if not number_text or number_text == "" or number_text == "-" then
    return _json_decode_error("invalid number", idx)
  end
  local num = tonumber(number_text)
  if num == nil then
    return _json_decode_error("invalid number", idx)
  end
  return num, idx + #number_text
end

local function _json_decode_array(text, idx)
  idx = idx + 1
  local out = {}
  idx = _json_skip_spaces(text, idx)
  if string_sub(text, idx, idx) == "]" then
    return out, idx + 1
  end
  while idx <= #text do
    local value
    value, idx = _json_decode_value(text, idx)
    if value == nil and type(idx) == "string" then
      return nil, idx
    end
    out[#out + 1] = value
    idx = _json_skip_spaces(text, idx)
    local ch = string_sub(text, idx, idx)
    if ch == "]" then
      return out, idx + 1
    end
    if ch ~= "," then
      return _json_decode_error("expected ',' or ']'", idx)
    end
    idx = _json_skip_spaces(text, idx + 1)
  end
  return _json_decode_error("unterminated array", idx)
end

local function _json_decode_object(text, idx)
  idx = idx + 1
  local out = {}
  idx = _json_skip_spaces(text, idx)
  if string_sub(text, idx, idx) == "}" then
    return out, idx + 1
  end
  while idx <= #text do
    if string_sub(text, idx, idx) ~= '"' then
      return _json_decode_error("expected object key string", idx)
    end
    local key
    key, idx = _json_decode_string(text, idx)
    if key == nil and type(idx) == "string" then
      return nil, idx
    end
    idx = _json_skip_spaces(text, idx)
    if string_sub(text, idx, idx) ~= ":" then
      return _json_decode_error("expected ':'", idx)
    end
    idx = _json_skip_spaces(text, idx + 1)
    local value
    value, idx = _json_decode_value(text, idx)
    if value == nil and type(idx) == "string" then
      return nil, idx
    end
    out[key] = value
    idx = _json_skip_spaces(text, idx)
    local ch = string_sub(text, idx, idx)
    if ch == "}" then
      return out, idx + 1
    end
    if ch ~= "," then
      return _json_decode_error("expected ',' or '}'", idx)
    end
    idx = _json_skip_spaces(text, idx + 1)
  end
  return _json_decode_error("unterminated object", idx)
end

_json_decode_value = function(text, idx)
  idx = _json_skip_spaces(text, idx)
  local ch = string_sub(text, idx, idx)
  if ch == '"' then
    return _json_decode_string(text, idx)
  end
  if ch == "{" then
    return _json_decode_object(text, idx)
  end
  if ch == "[" then
    return _json_decode_array(text, idx)
  end
  if ch == "t" and string_sub(text, idx, idx + 3) == "true" then
    return true, idx + 4
  end
  if ch == "f" and string_sub(text, idx, idx + 4) == "false" then
    return false, idx + 5
  end
  if ch == "n" and string_sub(text, idx, idx + 3) == "null" then
    return nil, idx + 4
  end
  return _json_decode_number(text, idx)
end

local function _json_decode(text)
  if type(text) ~= "string" then
    return nil, "json input must be a string"
  end
  local value, next_idx = _json_decode_value(text, 1)
  if value == nil and type(next_idx) == "string" then
    return nil, next_idx
  end
  next_idx = _json_skip_spaces(text, next_idx)
  if next_idx <= #text then
    return nil, "unexpected trailing data at position " .. tostring(next_idx)
  end
  return value
end

local _fairvisor_json = {
  encode = function(value)
    return _json_encode_value(value)
  end,
  decode = _json_decode,
}

-- Cached JSON lib (decode(s)->value,err; encode(t)->string,err). Built once on first use.
local _json_lib

local function _build_json_lib()
  if _json_lib ~= nil then
    return _json_lib
  end

  local ok_safe, cjson_safe = pcall(require, "cjson.safe")
  if ok_safe and cjson_safe and cjson_safe.decode then
    _json_lib = {
      decode = function(s)
        if type(s) ~= "string" then
          return nil, "input must be string"
        end
        local ok, v = pcall(cjson_safe.decode, s)
        if ok and v ~= nil then
          return v, nil
        end
        local err = (not ok and v) and tostring(v) or "json_parse_error"
        if not err:find("^json_parse_error") then
          err = "json_parse_error: " .. err
        end
        return nil, err
      end,
      encode = function(t)
        if cjson_safe.encode then
          local out = cjson_safe.encode(t)
          return out and out or nil, (out and nil or "json_encode_error")
        end
        return nil, "no encoder"
      end,
    }
    return _json_lib
  end

  local ok, cjson = pcall(require, "cjson")
  if ok and cjson and cjson.decode then
    _json_lib = {
      decode = function(s)
        if type(s) ~= "string" then
          return nil, "input must be string"
        end
        local ok_decode, v = pcall(cjson.decode, s)
        if ok_decode and v ~= nil then
          return v, nil
        end
        return nil, "json_parse_error: " .. tostring(v)
      end,
      encode = function(t)
        if cjson.encode then
          local ok_enc, out = pcall(cjson.encode, t)
          return (ok_enc and out) or nil, (ok_enc and nil or tostring(out))
        end
        return nil, "no encoder"
      end,
    }
    return _json_lib
  end

  _json_lib = {
    decode = function(s)
      if type(s) ~= "string" then
        return nil, "input must be string"
      end
      local v, err = _fairvisor_json.decode(s)
      if v ~= nil then
        return v, nil
      end
      err = err or "json_parse_error"
      if not err:find("^json_parse_error") then
        err = "json_parse_error: " .. err
      end
      return nil, err
    end,
    encode = function(t)
      local out, err = _fairvisor_json.encode(t)
      return out, err
    end,
  }
  return _json_lib
end

--- Return the shared JSON lib (decode(s)->value,err; encode(t)->string,err).
-- Chain: cjson.safe → cjson → inlined JSON (no unicode escapes). Single place for JSON; never nil.
function _M.get_json()
  return _build_json_lib()
end

--- Inlined JSON codec (same as fallback in get_json chain). Exposed for unit tests.
_M.fairvisor_json = _fairvisor_json

local function _to_utc_epoch(year, month, day, hour, min, sec)
  local local_epoch = os_time({
    year = year,
    month = month,
    day = day,
    hour = hour,
    min = min,
    sec = sec,
    isdst = false,
  })
  if not local_epoch then
    return nil
  end

  local local_table = os_date("*t", local_epoch)
  local utc_table = os_date("!*t", local_epoch)
  if not local_table or not utc_table then
    return nil
  end

  local tz_offset = os_difftime(os_time(local_table), os_time(utc_table))
  return local_epoch + tz_offset
end

--- Parse an ISO 8601 UTC timestamp to epoch seconds.
-- @param s (string) timestamp like "2026-02-03T14:00:00Z"
-- @return number|nil epoch seconds on success
-- @return string|nil error message on failure (when first return is nil)
function _M.parse_iso8601(s)
  if type(s) ~= "string" then
    return nil, "timestamp must be a string"
  end

  local year, month, day, hour, min, sec = string_match(s, "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not year then
    return nil, "timestamp must be ISO8601 UTC"
  end

  year = tonumber(year)
  month = tonumber(month)
  day = tonumber(day)
  hour = tonumber(hour)
  min = tonumber(min)
  sec = tonumber(sec)

  if month < 1 or month > 12 then
    return nil, "timestamp is invalid"
  end
  if day < 1 or day > 31 then
    return nil, "timestamp is invalid"
  end
  if hour > 23 or min > 59 or sec > 59 then
    return nil, "timestamp is invalid"
  end

  local epoch = _to_utc_epoch(year, month, day, hour, min, sec)
  if not epoch then
    return nil, "timestamp is invalid"
  end

  local check = os_date("!%Y-%m-%dT%H:%M:%SZ", epoch)
  if check ~= s then
    return nil, "timestamp is invalid"
  end

  return epoch, nil
end

return _M
