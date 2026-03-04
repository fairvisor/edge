local type = type
local tostring = tostring
local pairs = pairs
local write = io.write

local _M = {}

local function _safe_json_encode(value)
  local ok, cjson = pcall(require, "cjson")
  if not ok then
    return nil, "cjson module is not available"
  end

  local encode_ok, encoded = pcall(cjson.encode, value)
  if not encode_ok then
    return nil, encoded
  end

  return encoded
end

function _M.print_line(message)
  write((message or "") .. "\n")
end

function _M.print_error(message)
  io.stderr:write("Error: " .. (message or "") .. "\n")
end

function _M.print_warning(message)
  io.stderr:write("Warning: " .. (message or "") .. "\n")
end

function _M.emit(data, format)
  local output_format = format or "table"

  if output_format == "json" then
    local encoded, err = _safe_json_encode(data)
    if not encoded then
      return nil, "cannot encode json output: " .. err
    end
    _M.print_line(encoded)
    return true
  end

  if type(data) == "table" then
    for key, value in pairs(data) do
      _M.print_line(key .. ": " .. tostring(value))
    end
    return true
  end

  _M.print_line(tostring(data))
  return true
end

return _M
