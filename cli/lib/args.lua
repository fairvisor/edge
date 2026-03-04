local sub = string.sub
local find = string.find

local _M = {}

local function _normalize_flag_name(name)
  if sub(name, 1, 2) == "--" then
    return sub(name, 3)
  end
  return name
end

function _M.parse(argv, start_index)
  local args = argv or {}
  local index = start_index or 1
  local flags = {}
  local positional = {}

  while index <= #args do
    local token = args[index]
    if type(token) == "string" and sub(token, 1, 2) == "--" then
      local eq = find(token, "=", 1, true)
      if eq then
        local key = _normalize_flag_name(sub(token, 1, eq - 1))
        local value = sub(token, eq + 1)
        flags[key] = value
      else
        local key = _normalize_flag_name(token)
        local next_token = args[index + 1]
        if type(next_token) == "string" and sub(next_token, 1, 2) ~= "--" then
          flags[key] = next_token
          index = index + 1
        else
          flags[key] = true
        end
      end
    else
      positional[#positional + 1] = token
    end

    index = index + 1
  end

  return {
    flags = flags,
    positional = positional,
  }
end

function _M.get_flag(parsed, name, default_value)
  if type(parsed) ~= "table" then
    return default_value
  end

  local key = _normalize_flag_name(name)
  local flags = parsed.flags or {}
  local value = flags[key]
  if value == nil then
    return default_value
  end
  return value
end

return _M
