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

runner:given("^kill switches are nil$", function(ctx)
  ctx.kill_switches = nil
end)

runner:given("^kill switches are an empty list$", function(ctx)
  ctx.kill_switches = {}
end)

runner:given('^kill switches include scope "([^"]+)" value "([^"]+)"$', function(ctx, scope_key, scope_value)
  ctx.kill_switches = {
    {
      scope_key = scope_key,
      scope_value = scope_value,
    },
  }
end)

runner:given('^kill switches include scope "([^"]+)" value "([^"]+)" on route "([^"]+)"$',
  function(ctx, scope_key, scope_value, route)
    ctx.kill_switches = {
      {
        scope_key = scope_key,
        scope_value = scope_value,
        route = route,
      },
    }
  end
)

runner:given('^kill switches include scope "([^"]+)" with missing scope value$', function(ctx, scope_key)
  ctx.kill_switches = {
    {
      scope_key = scope_key,
    },
  }
end)

runner:given('^kill switches include scope "([^"]+)" value "([^"]+)" expiring at "([^"]+)"$',
  function(ctx, scope_key, scope_value, expires_at)
    ctx.kill_switches = {
      {
        scope_key = scope_key,
        scope_value = scope_value,
        expires_at = expires_at,
      },
    }
  end
)

runner:given('^two kill switches include "([^"]+)" then "([^"]+)" for scope "([^"]+)"$',
  function(ctx, first_value, second_value, scope_key)
    ctx.kill_switches = {
      {
        scope_key = scope_key,
        scope_value = first_value,
        reason = "first",
      },
      {
        scope_key = scope_key,
        scope_value = second_value,
        reason = "second",
      },
    }
  end
)

runner:given("^descriptors are nil$", function(ctx)
  ctx.descriptors = nil
end)

runner:given('^descriptors include "([^"]+)" as "([^"]+)"$', function(ctx, scope_key, scope_value)
  ctx.descriptors = {
    [scope_key] = scope_value,
  }
end)

runner:given('^descriptors include "([^"]+)" as "([^"]+)" and "([^"]+)" as "([^"]+)"$',
  function(ctx, key1, value1, key2, value2)
    ctx.descriptors = {
      [key1] = value1,
      [key2] = value2,
    }
  end
)

runner:given('^the route is "([^"]+)"$', function(ctx, route)
  ctx.route = route
end)

runner:given('^the current time is ISO "([^"]+)"$', function(ctx, iso)
  ctx.now = kill_switch.parse_iso8601(iso)
end)

runner:given("^the current time is now$", function(ctx)
  ctx.now = ctx.time.now()
end)

runner:when("^I validate kill switches$", function(ctx)
  ctx.ok, ctx.err = kill_switch.validate(ctx.kill_switches)
end)

runner:when("^I check kill switches$", function(ctx)
  ctx.result = _copy_result(kill_switch.check(ctx.kill_switches, ctx.descriptors, ctx.route, ctx.now or 0))
end)

runner:when('^I parse timestamp "([^"]+)"$', function(ctx, iso)
  ctx.epoch = kill_switch.parse_iso8601(iso)
end)

runner:then_("^validation succeeds$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
end)

runner:then_('^validation fails with error containing "([^"]+)"$', function(ctx, fragment)
  assert.is_nil(ctx.ok)
  assert.is_truthy(ctx.err)
  assert.is_not_nil(string.find(ctx.err, fragment, 1, true))
end)

runner:then_("^the kill switch has cached expiry epoch$", function(ctx)
  assert.is_true(type(ctx.kill_switches[1]._expires_epoch) == "number")
end)

runner:then_("^result is not matched$", function(ctx)
  assert.is_false(ctx.result.matched)
  assert.is_nil(ctx.result.reason)
end)

runner:then_("^result is matched with kill_switch reason$", function(ctx)
  assert.is_true(ctx.result.matched)
  assert.equals("kill_switch", ctx.result.reason)
end)

runner:then_('^result includes scope "([^"]+)" and value "([^"]+)"$', function(ctx, scope_key, scope_value)
  assert.equals(scope_key, ctx.result.scope_key)
  assert.equals(scope_value, ctx.result.scope_value)
end)

runner:then_('^result route is "([^"]+)"$', function(ctx, route)
  assert.equals(route, ctx.result.route)
end)

runner:then_('^result reason text is "([^"]+)"$', function(ctx, reason)
  assert.equals(reason, ctx.result.ks_reason)
end)

runner:then_("^parsed epoch is present$", function(ctx)
  assert.is_true(type(ctx.epoch) == "number")
end)

runner:then_("^parsed epoch is nil$", function(ctx)
  assert.is_nil(ctx.epoch)
end)

runner:feature_file_relative("features/kill_switch.feature")
