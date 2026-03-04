package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local circuit_breaker = require("fairvisor.circuit_breaker")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _copy_result(result)
  return {
    tripped = result.tripped,
    state = result.state,
    spend_rate = result.spend_rate,
    reason = result.reason,
    alert = result.alert,
  }
end

runner:given("^the nginx mock environment is reset$", function(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.dict = env.dict
  ctx.time = env.time

  ctx.config = {
    enabled = true,
    spend_rate_threshold_per_minute = 100,
    action = "reject",
    alert = true,
    auto_reset_after_minutes = 5,
  }

  local ok, err = circuit_breaker.validate_config(ctx.config)
  assert.is_true(ok, err)
  ctx.limit_key = "org-1"
end)

runner:given("^a threshold of (%d+) and auto_reset_after_minutes (%d+)$", function(ctx, threshold, minutes)
  ctx.config.spend_rate_threshold_per_minute = tonumber(threshold)
  ctx.config.auto_reset_after_minutes = tonumber(minutes)
end)

runner:given("^I apply (%d+) requests with cost (%d+)$", function(ctx, count, cost)
  for _ = 1, tonumber(count) do
    ctx.last_result = _copy_result(circuit_breaker.check(ctx.dict, ctx.config, ctx.limit_key, tonumber(cost), ctx.time.now()))
  end
end)

runner:given("^the breaker is opened now$", function(ctx)
  local state_key = circuit_breaker.build_state_key(ctx.limit_key)
  ctx.dict:set(state_key, "open:" .. tostring(ctx.time.now()))
end)

runner:given("^time advances by (%d+) minutes$", function(ctx, minutes)
  ctx.time.advance_time(tonumber(minutes) * 60)
end)

runner:when("^I run one request with cost (%d+)$", function(ctx, cost)
  ctx.last_result = _copy_result(circuit_breaker.check(ctx.dict, ctx.config, ctx.limit_key, tonumber(cost), ctx.time.now()))
end)

runner:then_('^the result is tripped (%a+) with state "([^"]+)"$', function(ctx, tripped, state)
  assert.equals(tripped == "true", ctx.last_result.tripped)
  assert.equals(state, ctx.last_result.state)
end)

runner:then_("^the spend_rate is (%d+)$", function(ctx, spend_rate)
  assert.equals(tonumber(spend_rate), ctx.last_result.spend_rate)
end)

runner:then_('^the reason is "([^"]+)"$', function(ctx, reason)
  assert.equals(reason, ctx.last_result.reason)
end)

runner:then_("^the alert is (%a+)$", function(ctx, alert)
  assert.equals(alert == "true", ctx.last_result.alert)
end)

runner:feature_file_relative("features/circuit_breaker.feature")
