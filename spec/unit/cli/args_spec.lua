package.path = "./cli/?.lua;./cli/?/init.lua;./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local args = require("cli.lib.args")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

runner:given("^an argv with command and mixed flags$", function(ctx)
  ctx.argv = {
    "validate",
    "policy.json",
    "--format=json",
    "--edge-url",
    "http://localhost:8080",
    "--dry-run",
  }
end)

runner:when("^I parse arguments from index (%d+)$", function(ctx, index)
  ctx.parsed = args.parse(ctx.argv, tonumber(index))
end)

runner:then_("^the positional argument is policy%.json$", function(ctx)
  assert.equals("policy.json", ctx.parsed.positional[1])
end)

runner:then_("^the format flag is json$", function(ctx)
  assert.equals("json", args.get_flag(ctx.parsed, "format"))
end)

runner:then_("^the edge%-url flag is http://localhost:8080$", function(ctx)
  assert.equals("http://localhost:8080", args.get_flag(ctx.parsed, "--edge-url"))
end)

runner:then_("^the dry%-run flag is true$", function(ctx)
  assert.is_true(args.get_flag(ctx.parsed, "dry-run"))
end)

runner:given("^an argv with only command$", function(ctx)
  ctx.argv = { "help" }
end)

runner:then_("^get_flag returns default when absent$", function(ctx)
  assert.equals("table", args.get_flag(ctx.parsed, "format", "table"))
end)

local ok, err = runner:feature([[
Feature: CLI argument parsing
  Rule: Positional and flag arguments are parsed deterministically
    Scenario: Mixed positional and flag styles are supported
      Given an argv with command and mixed flags
      When I parse arguments from index 2
      Then the positional argument is policy.json
      And the format flag is json
      And the edge-url flag is http://localhost:8080
      And the dry-run flag is true

    Scenario: Missing flags fall back to defaults
      Given an argv with only command
      When I parse arguments from index 2
      Then get_flag returns default when absent
]])

assert.is_true(ok)
assert.is_nil(err)
