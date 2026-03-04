local output = require("cli.lib.output")

-- In OpenResty resty context the main chunk varargs may be empty;
-- fall back to the global `arg` table (arg[1] = first CLI argument).
local args = { ... }
if #args == 0 and type(arg) == "table" and arg[1] then
  args = arg
end
local command = args[1]

local commands = {
  init = "cli.commands.init",
  validate = "cli.commands.validate",
  test = "cli.commands.test",
  connect = "cli.commands.connect",
  status = "cli.commands.status",
  logs = "cli.commands.logs",
  version = "cli.commands.version",
  help = "cli.commands.help",
}

local function _print_usage()
  output.print_line("Usage: fairvisor <command> [options]")
  output.print_line("Run 'fairvisor help' for command list")
end

if not command then
  _print_usage()
  os.exit(3)
end

local module_name = commands[command]
if not module_name then
  output.print_error("unknown command: " .. command)
  _print_usage()
  os.exit(3)
end

local ok_require, handler_or_err = pcall(require, module_name)
if not ok_require then
  output.print_error("failed to load command '" .. command .. "': " .. handler_or_err)
  os.exit(1)
end

if type(handler_or_err) ~= "table" or type(handler_or_err.run) ~= "function" then
  output.print_error("command module does not expose run(): " .. command)
  os.exit(1)
end

local ok_run, ok, exit_code = pcall(handler_or_err.run, args)
if not ok_run then
  output.print_error("command failed: " .. ok)
  os.exit(1)
end

if not ok then
  os.exit(exit_code or 1)
end

os.exit(exit_code or 0)
