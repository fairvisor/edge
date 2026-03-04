package.path = "./cli/?.lua;./cli/?/init.lua;./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local init_command = require("cli.commands.init")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _read_file(path)
  local handle = io.open(path, "r")
  if not handle then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function _remove(path)
  os.remove(path)
end

runner:given("^the scaffold output files are cleaned$", function()
  _remove("policy.json")
  _remove("edge.env.example")
end)

runner:when("^I run fairvisor init with default template$", function(ctx)
  ctx.ok, ctx.code = init_command.run({ "init" })
end)

runner:then_("^init succeeds with exit code 0$", function(ctx)
  assert.is_true(ctx.ok)
  assert.equals(0, ctx.code)
end)

runner:then_("^policy%.json and edge%.env%.example are created$", function()
  assert.is_truthy(_read_file("policy.json"))
  assert.is_truthy(_read_file("edge.env.example"))
end)

runner:then_("^policy%.json contains api template path prefix$", function()
  local content = _read_file("policy.json")
  assert.is_truthy(content)
  assert.is_truthy(content:find("/api/", 1, true))
end)

runner:when("^I run fairvisor init with llm template$", function(ctx)
  ctx.ok, ctx.code = init_command.run({ "init", "--template=llm" })
end)

runner:then_("^policy%.json contains llm TPM and loop detection settings$", function()
  local content = _read_file("policy.json")
  assert.is_truthy(content:find("tokens_per_minute", 1, true))
  assert.is_truthy(content:find("loop_detection", 1, true))
end)

runner:when("^I run fairvisor init with unknown template$", function(ctx)
  ctx.ok, ctx.code = init_command.run({ "init", "--template=unknown" })
end)

runner:then_("^init fails with usage exit code 3$", function(ctx)
  assert.is_nil(ctx.ok)
  assert.equals(3, ctx.code)
end)

local ok, err = runner:feature([[
Feature: fairvisor init command
  Rule: Project scaffolding is generated from built-in templates
    Scenario: Default init writes scaffold files
      Given the scaffold output files are cleaned
      When I run fairvisor init with default template
      Then init succeeds with exit code 0
      And policy.json and edge.env.example are created
      And policy.json contains api template path prefix

    Scenario: LLM template includes LLM-specific rules
      Given the scaffold output files are cleaned
      When I run fairvisor init with llm template
      Then init succeeds with exit code 0
      And policy.json contains llm TPM and loop detection settings

    Scenario: Unknown template returns usage failure
      Given the scaffold output files are cleaned
      When I run fairvisor init with unknown template
      Then init fails with usage exit code 3
]])

assert.is_true(ok)
assert.is_nil(err)
