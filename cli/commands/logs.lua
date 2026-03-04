local args = require("cli.lib.args")
local output = require("cli.lib.output")

local _M = {}

local function _decode_json(line)
  local ok, cjson = pcall(require, "cjson")
  if not ok then
    return nil, "cjson module is not available"
  end

  local decode_ok, parsed = pcall(cjson.decode, line)
  if not decode_ok then
    return nil
  end

  return parsed
end

local function _matches(entry, action_filter, reason_filter)
  if action_filter and entry.action ~= action_filter then
    return false
  end

  if reason_filter and entry.reason ~= reason_filter then
    return false
  end

  return true
end

function _M.run(argv)
  local parsed = args.parse(argv, 2)
  local action_filter = args.get_flag(parsed, "action")
  local reason_filter = args.get_flag(parsed, "reason")

  while true do
    local line = io.read("*l")
    if not line then
      break
    end

    local entry = _decode_json(line)
    if entry and _matches(entry, action_filter, reason_filter) then
      output.print_line(line)
    end
  end

  return true, 0
end

return _M
