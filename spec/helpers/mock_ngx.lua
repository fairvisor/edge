local type = type
local string_byte = string.byte
local string_char = string.char
local string_sub = string.sub
local string_find = string.find
local table_concat = table.concat

local _M = {}
local string_byte = string.byte

local _BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function _to_base64(input)
  local bytes = { string_byte(input, 1, #input) }
  local out = {}
  local index = 1

  while index <= #bytes do
    local b1 = bytes[index] or 0
    local b2 = bytes[index + 1] or 0
    local b3 = bytes[index + 2] or 0
    local pad = 0

    if bytes[index + 1] == nil then
      pad = 2
    elseif bytes[index + 2] == nil then
      pad = 1
    end

    local n = b1 * 65536 + b2 * 256 + b3
    local c1 = math.floor(n / 262144) % 64 + 1
    local c2 = math.floor(n / 4096) % 64 + 1
    local c3 = math.floor(n / 64) % 64 + 1
    local c4 = n % 64 + 1

    out[#out + 1] = string_sub(_BASE64_ALPHABET, c1, c1)
    out[#out + 1] = string_sub(_BASE64_ALPHABET, c2, c2)

    if pad == 2 then
      out[#out + 1] = "="
      out[#out + 1] = "="
    elseif pad == 1 then
      out[#out + 1] = string_sub(_BASE64_ALPHABET, c3, c3)
      out[#out + 1] = "="
    else
      out[#out + 1] = string_sub(_BASE64_ALPHABET, c3, c3)
      out[#out + 1] = string_sub(_BASE64_ALPHABET, c4, c4)
    end

    index = index + 3
  end

  return table_concat(out)
end

local function _from_base64(input)
  local clean = input:gsub("%s", "")
  local out = {}
  local index = 1

  while index <= #clean do
    local c1 = string_sub(clean, index, index)
    local c2 = string_sub(clean, index + 1, index + 1)
    local c3 = string_sub(clean, index + 2, index + 2)
    local c4 = string_sub(clean, index + 3, index + 3)

    if c1 == "" or c2 == "" then
      break
    end

    local v1 = string_find(_BASE64_ALPHABET, c1, 1, true)
    local v2 = string_find(_BASE64_ALPHABET, c2, 1, true)
    local v3 = c3 ~= "=" and string_find(_BASE64_ALPHABET, c3, 1, true) or nil
    local v4 = c4 ~= "=" and string_find(_BASE64_ALPHABET, c4, 1, true) or nil

    if not v1 or not v2 then
      return nil
    end

    v1 = v1 - 1
    v2 = v2 - 1
    v3 = v3 and (v3 - 1) or 0
    v4 = v4 and (v4 - 1) or 0

    local n = v1 * 262144 + v2 * 4096 + v3 * 64 + v4
    local b1 = math.floor(n / 65536) % 256
    local b2 = math.floor(n / 256) % 256
    local b3 = n % 256

    out[#out + 1] = string_char(b1)
    if c3 ~= "=" then
      out[#out + 1] = string_char(b2)
    end
    if c4 ~= "=" then
      out[#out + 1] = string_char(b3)
    end

    index = index + 4
  end

  return table_concat(out)
end

local function _simple_digest(input)
  local h1 = 2166136261
  local h2 = 16777619
  for i = 1, #input do
    local b = string_byte(input, i)
    h1 = (h1 ~ b) % 4294967296
    h1 = (h1 * 16777619) % 4294967296
    h2 = (h2 + (b * i)) % 4294967296
  end

  local parts = {}
  for i = 1, 8 do
    local a = (h1 + (i * 2654435761)) % 4294967296
    local b = (h2 + (i * 2246822519)) % 4294967296
    parts[#parts + 1] = string_char(math.floor(a / 16777216) % 256)
    parts[#parts + 1] = string_char(math.floor(a / 65536) % 256)
    parts[#parts + 1] = string_char(math.floor(b / 256) % 256)
    parts[#parts + 1] = string_char(b % 256)
  end

  return table_concat(parts)
end

function _M.mock_shared_dict()
  local data = {}

  return {
    get = function(_, key)
      return data[key]
    end,
    set = function(_, key, value)
      data[key] = value
      return true
    end,
    incr = function(_, key, value, init, _init_ttl)
      local current = data[key]
      if current == nil then
        if init then
          data[key] = init + value
          return data[key], nil, true
        end
        return nil, "not found"
      end

      data[key] = current + value
      return data[key], nil, false
    end,
    delete = function(_, key)
      data[key] = nil
    end,
    flush_all = function(_)
      data = {}
    end,
  }
end

function _M.setup_time_mock()
  local mock_time = 1000.000

  local function now()
    return mock_time
  end

  local function advance_time(seconds)
    mock_time = mock_time + seconds
  end

  local function set_time(seconds)
    mock_time = seconds
  end

  return {
    now = now,
    advance_time = advance_time,
    set_time = set_time,
  }
end

function _M.setup_ngx()
  local time = _M.setup_time_mock()
  local dict = _M.mock_shared_dict()
  local logs = {}
  local timers = {}

  local function crc32_short(value)
    local hash = 0
    local input = tostring(value or "")
    for i = 1, #input do
      hash = (hash * 33 + string_byte(input, i)) % 4294967296
    end
    return hash
  end

  _G.ngx = {
    now = time.now,
    update_time = function()
    end,
    shared = {
      fairvisor_counters = dict,
    },
    log = function(...)
      logs[#logs + 1] = { ... }
    end,
    timer = {
      every = function(interval, callback)
        timers[#timers + 1] = { interval = interval, callback = callback }
        return true
      end,
    },
    hmac_sha256 = function(key, payload)
      return _simple_digest(key .. ":" .. payload)
    end,
    hmac_sha1 = function(key, payload)
      return _simple_digest("sha1:" .. key .. ":" .. payload)
    end,
    sha1_bin = function(payload)
      return _simple_digest("sha1bin:" .. payload)
    end,
    encode_base64 = function(value)
      return _to_base64(value)
    end,
    decode_base64 = function(value)
      return _from_base64(value)
    end,
    md5 = function(payload)
      return _to_base64(_simple_digest("md5:" .. payload))
    end,
    ERR = 1,
    WARN = 2,
    INFO = 3,
    DEBUG = 4,
    crc32_short = crc32_short,
  }

  return {
    time = time,
    dict = dict,
    logs = logs,
    timers = timers,
  }
end

return _M
