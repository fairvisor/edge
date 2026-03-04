package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local kill_switch = require("fairvisor.kill_switch")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _copy_result(result)
  return {
    matched = result.matched,
    reason = result.reason,
    scope_key = result.scope_key,
    scope_value = result.scope_value,
    route = result.route,
    ks_reason = result.ks_reason,
  }
end

runner:given("^the nginx mock environment is reset$", function(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.time = env.time
end)

runner:given("^a mixed kill.* bundle is configured$", function(ctx)
  ctx.kill_switches = {
    {
      scope_key = "jwt:org_id",
      scope_value = "org_old",
      route = "/v1/inference",
      reason = "expired",
      expires_at = "2026-02-03T10:00:00Z",
    },
    {
      scope_key = "jwt:org_id",
      scope_value = "org_xyz",
      route = "/v1/inference",
      reason = "route block",
    },
    {
      scope_key = "header:X_API_Key",
      scope_value = "key-123",
      reason = "global key block",
    },
  }
end)

runner:given('^descriptors contain org "([^"]+)" and api key "([^"]+)"$', function(ctx, org_id, api_key)
  ctx.descriptors = {
    ["jwt:org_id"] = org_id,
    ["header:X_API_Key"] = api_key,
  }
end)

runner:given('^descriptors contain org "([^"]+)" only$', function(ctx, org_id)
  ctx.descriptors = {
    ["jwt:org_id"] = org_id,
  }
end)

runner:given('^the route is "([^"]+)"$', function(ctx, route)
  ctx.route = route
end)

runner:given('^the request time is "([^"]+)"$', function(ctx, iso)
  ctx.now = kill_switch.parse_iso8601(iso)
end)

runner:when("^I validate the kill.* bundle$", function(ctx)
  ctx.ok, ctx.err = kill_switch.validate(ctx.kill_switches)
end)

runner:when("^I run kill.* evaluation$", function(ctx)
  ctx.result = _copy_result(kill_switch.check(ctx.kill_switches, ctx.descriptors, ctx.route, ctx.now))
end)

runner:then_("^bundle validation succeeds$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
end)

runner:then_("^the request is rejected by kill.*$", function(ctx)
  assert.is_true(ctx.result.matched)
  assert.equals("kill_switch", ctx.result.reason)
end)

runner:then_('^the matched scope key is "([^"]+)"$', function(ctx, expected)
  assert.equals(expected, ctx.result.scope_key)
end)

runner:then_('^the matched scope value is "([^"]+)"$', function(ctx, expected)
  assert.equals(expected, ctx.result.scope_value)
end)

runner:then_('^the matched kill.* reason is "([^"]+)"$', function(ctx, expected)
  assert.equals(expected, ctx.result.ks_reason)
end)

runner:then_("^the request is not rejected by kill.*$", function(ctx)
  assert.is_false(ctx.result.matched)
  assert.is_nil(ctx.result.reason)
end)

runner:feature_file_relative("features/kill_switch.feature")
