local output = require("cli.lib.output")

local _M = {}

local HELP_TEXT = {
  "Usage: fairvisor <command> [options]",
  "",
  "Commands:",
  "  init [--template=api|llm|webhook]",
  "  validate <file|- >",
  "  test <file> [--requests=<file>] [--format=table|json]",
  "  connect [--token=TOKEN] [--url=URL] [--output=PATH]",
  "  status [--edge-url=URL] [--format=table|json]",
  "  logs [--action=ACTION] [--reason=REASON]",
  "  version",
  "  help",
}

function _M.run(_argv)
  for _, line in ipairs(HELP_TEXT) do
    output.print_line(line)
  end
  return true, 0
end

return _M
