local sub = string.sub
local gsub = string.gsub

local args = require("cli.lib.args")
local output = require("cli.lib.output")

local _M = {}

local ENV_TEMPLATE = [[FAIRVISOR_EDGE_ID=
FAIRVISOR_EDGE_TOKEN=
FAIRVISOR_SAAS_URL=https://api.fairvisor.com
FAIRVISOR_EDGE_URL=http://localhost:8080
]]

local function _dirname(path)
  local normalized = gsub(path, "\\", "/")
  return normalized:match("^(.+)/[^/]+$") or "."
end

local function _read_file(path)
  local handle, err = io.open(path, "r")
  if not handle then
    return nil, err
  end

  local content = handle:read("*a")
  handle:close()
  return content
end

local function _write_file(path, content)
  local handle, err = io.open(path, "w")
  if not handle then
    return nil, err
  end

  handle:write(content)
  handle:close()
  return true
end

local function _load_template(name)
  local source = debug.getinfo(1, "S").source
  local this_file = source
  if sub(this_file, 1, 1) == "@" then
    this_file = sub(this_file, 2)
  end

  local commands_dir = _dirname(this_file)
  local cli_dir = _dirname(commands_dir)
  local path = cli_dir .. "/templates/" .. name .. ".json"
  local content = _read_file(path)
  if content then
    return content
  end
  -- Fallback: templates relative to CWD (e.g. when source path is not as expected)
  return _read_file("templates/" .. name .. ".json")
end

function _M.run(argv)
  local parsed = args.parse(argv, 2)
  local template_name = args.get_flag(parsed, "template", "api")

  if template_name ~= "api" and template_name ~= "llm" and template_name ~= "webhook" then
    output.print_error("unknown template: " .. template_name)
    return nil, 3
  end

  local template, read_err = _load_template(template_name)
  if not template then
    output.print_error("cannot read template '" .. template_name .. "': " .. read_err)
    return nil, 1
  end

  local ok, write_err = _write_file("policy.json", template .. "\n")
  if not ok then
    output.print_error("cannot write policy.json: " .. write_err)
    return nil, 1
  end

  ok, write_err = _write_file("edge.env.example", ENV_TEMPLATE)
  if not ok then
    output.print_error("cannot write edge.env.example: " .. write_err)
    return nil, 1
  end

  output.print_line("Created policy.json and edge.env.example")
  return true, 0
end

return _M
