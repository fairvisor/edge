local output = require("cli.lib.output")

local _M = {}
local VERSION = require("cli.version_const")

function _M.run(_argv)
  output.print_line("fairvisor " .. VERSION)
  return true, 0
end

return _M
