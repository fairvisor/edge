package.path = "./cli/?.lua;./cli/?/init.lua;./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local version_command = require("cli.commands.version")
local version_const = require("cli.version_const")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

runner:when("^I run fairvisor version$", function(ctx)
  ctx.ok, ctx.code = version_command.run({ "version" })
end)

runner:then_("^version succeeds with exit code 0$", function(ctx)
  assert.is_true(ctx.ok)
  assert.equals(0, ctx.code)
end)

runner:then_("^version constant matches expected format$", function()
  assert.is_string(version_const)
  assert.is_truthy(version_const:match("^%d+%.%d+%.%d+"))
end)

runner:feature([[
Feature: version command
  Rule: version prints CLI version and exits 0
    Scenario: fairvisor version exits 0
      When I run fairvisor version
      Then version succeeds with exit code 0
    Scenario: version constant is semver-like
      Then version constant matches expected format
]])
