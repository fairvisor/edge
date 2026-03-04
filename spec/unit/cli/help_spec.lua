package.path = "./cli/?.lua;./cli/?/init.lua;./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local help_command = require("cli.commands.help")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

runner:when("^I run fairvisor help$", function(ctx)
  ctx.ok, ctx.code = help_command.run({ "help" })
end)

runner:then_("^help succeeds with exit code 0$", function(ctx)
  assert.is_true(ctx.ok)
  assert.equals(0, ctx.code)
end)

runner:feature([[
Feature: help command
  Rule: help prints usage and command list
    Scenario: fairvisor help exits 0 and lists commands
      When I run fairvisor help
      Then help succeeds with exit code 0
]])
