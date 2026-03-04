package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local original_getenv = os.getenv

local function _reload_module()
  package.loaded["fairvisor.env_config"] = nil
  return require("fairvisor.env_config")
end

runner:given("^the environment is reset$", function(ctx)
  ctx.env = {}
  os.getenv = function(name)
    return ctx.env[name]
  end
end)

runner:given('^env var "([^"]+)" is "([^"]*)"$', function(ctx, name, value)
  ctx.env[name] = value
end)

runner:given('^env var "([^"]+)" is unset$', function(ctx, name)
  ctx.env[name] = nil
end)

runner:when("^I load edge environment config$", function(ctx)
  ctx.env_config = _reload_module()
  ctx.config = ctx.env_config.load()
end)

runner:when("^I validate the loaded config$", function(ctx)
  ctx.ok, ctx.err = ctx.env_config.validate(ctx.config)
end)

runner:when("^I check standalone mode$", function(ctx)
  ctx.standalone = ctx.env_config.is_standalone(ctx.config)
end)

runner:then_("^validation succeeds$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
end)

runner:then_('^validation fails with "([^"]+)"$', function(ctx, expected)
  assert.is_nil(ctx.ok)
  assert.equals(expected, ctx.err)
end)

runner:then_('^config field "([^"]+)" equals "([^"]*)"$', function(ctx, field, value)
  assert.equals(value, tostring(ctx.config[field]))
end)

runner:then_("^config field " .. '"([^"]+)" equals number (%d+)$', function(ctx, field, value)
  assert.equals(tonumber(value), ctx.config[field])
end)

runner:then_("^standalone mode is true$", function(ctx)
  assert.is_true(ctx.standalone)
end)

runner:then_("^standalone mode is false$", function(ctx)
  assert.is_false(ctx.standalone)
end)

runner:feature([[
Feature: Environment configuration loading and validation
  Rule: Configuration can run in SaaS or standalone mode
    Scenario: SaaS mode with explicit values validates successfully
      Given the environment is reset
      And env var "FAIRVISOR_EDGE_ID" is "edge-1"
      And env var "FAIRVISOR_EDGE_TOKEN" is "tok-1"
      And env var "FAIRVISOR_SAAS_URL" is "https://api.example.test"
      And env var "FAIRVISOR_MODE" is "decision_service"
      When I load edge environment config
      And I validate the loaded config
      And I check standalone mode
      Then validation succeeds
      And standalone mode is false
      And config field "edge_id" equals "edge-1"
      And config field "saas_url" equals "https://api.example.test"

    Scenario: Standalone mode validates without SaaS variables or EDGE_ID
      Given the environment is reset
      And env var "FAIRVISOR_CONFIG_FILE" is "/etc/fairvisor/policy.json"
      When I load edge environment config
      And I validate the loaded config
      And I check standalone mode
      Then validation succeeds
      And standalone mode is true

    Scenario: Defaults are applied for optional numeric values
      Given the environment is reset
      And env var "FAIRVISOR_EDGE_ID" is "edge-defaults"
      And env var "FAIRVISOR_CONFIG_FILE" is "/tmp/policy.json"
      When I load edge environment config
      Then config field "config_poll_interval" equals number 30
      And config field "heartbeat_interval" equals number 5
      And config field "event_flush_interval" equals number 60
      And config field "shared_dict_size" equals "128m"
      And config field "log_level" equals "info"
      And config field "mode" equals "decision_service"

  Rule: Invalid combinations are rejected
    Scenario: Missing edge id is rejected
      Given the environment is reset
      And env var "FAIRVISOR_SAAS_URL" is "https://api.example.test"
      And env var "FAIRVISOR_EDGE_TOKEN" is "tok-1"
      When I load edge environment config
      And I validate the loaded config
      Then validation fails with "required environment variable FAIRVISOR_EDGE_ID is not set for SaaS mode"

    Scenario: Missing mode source is rejected
      Given the environment is reset
      And env var "FAIRVISOR_EDGE_ID" is "edge-missing"
      When I load edge environment config
      And I validate the loaded config
      Then validation fails with "either FAIRVISOR_SAAS_URL or FAIRVISOR_CONFIG_FILE must be set"

    Scenario: SaaS mode requires token
      Given the environment is reset
      And env var "FAIRVISOR_EDGE_ID" is "edge-saas"
      And env var "FAIRVISOR_SAAS_URL" is "https://api.example.test"
      When I load edge environment config
      And I validate the loaded config
      Then validation fails with "required environment variable FAIRVISOR_EDGE_TOKEN is not set for SaaS mode"

    Scenario: Reverse proxy mode requires backend url
      Given the environment is reset
      And env var "FAIRVISOR_EDGE_ID" is "edge-rp"
      And env var "FAIRVISOR_CONFIG_FILE" is "/tmp/policy.json"
      And env var "FAIRVISOR_MODE" is "reverse_proxy"
      When I load edge environment config
      And I validate the loaded config
      Then validation fails with "FAIRVISOR_BACKEND_URL is required when FAIRVISOR_MODE=reverse_proxy"
]])

describe("env_config cleanup", function()
  it("restores os.getenv", function()
    os.getenv = original_getenv
    assert.is_function(os.getenv)
  end)
end)
