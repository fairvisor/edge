package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local floor = math.floor

local circuit_breaker = require("fairvisor.circuit_breaker")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _copy_result(result)
  return {
    tripped = result.tripped,
    state = result.state,
    spend_rate = result.spend_rate,
    threshold = result.threshold,
    reason = result.reason,
    alert = result.alert,
  }
end

local function _window_start(now)
  return floor(now / 60) * 60
end

runner:given("^the nginx mock environment is reset$", function(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.dict = env.dict
  ctx.time = env.time
  ctx.limit_key = "org-1"
  ctx.config = {
    enabled = true,
    spend_rate_threshold_per_minute = 1000,
    action = "reject",
    alert = false,
    auto_reset_after_minutes = 5,
  }
end)

runner:given("^circuit breaker threshold is (%d+) and auto_reset_after_minutes is (%d+)$", function(ctx, threshold, minutes)
  ctx.config.spend_rate_threshold_per_minute = tonumber(threshold)
  ctx.config.auto_reset_after_minutes = tonumber(minutes)
end)

runner:given("^circuit breaker alert is (%a+)$", function(ctx, alert)
  ctx.config.alert = alert == "true"
end)

runner:given('^the breaker is open for limit key "([^"]+)"$', function(ctx, limit_key)
  ctx.limit_key = limit_key
  local state_key = circuit_breaker.build_state_key(limit_key)
  ctx.dict:set(state_key, "open:" .. tostring(ctx.time.now()))
end)

runner:given('^the limit key is "([^"]+)"$', function(ctx, limit_key)
  ctx.limit_key = limit_key
end)

runner:given("^(%d+) cost units accumulated in the current window$", function(ctx, total)
  local current_window = _window_start(ctx.time.now())
  local current_key = circuit_breaker.build_rate_key(ctx.limit_key, current_window)
  ctx.dict:set(current_key, tonumber(total))
end)

runner:given("^a dict that fails set for state key is used$", function(ctx)
  local state_prefix = "cb_state:"
  ctx.set_fail_dict = {
    get = function(_, key)
      return ctx.dict:get(key)
    end,
    set = function(_, key, value)
      if key and string.sub(key, 1, #state_prefix) == state_prefix then
        return nil, "no memory"
      end
      return ctx.dict:set(key, value)
    end,
    incr = function(_, key, value, init, init_ttl)
      return ctx.dict:incr(key, value, init, init_ttl)
    end,
    delete = function(_, key)
      return ctx.dict:delete(key)
    end,
  }
end)

runner:given("^the breaker opened (%d+) minutes ago$", function(ctx, minutes)
  local opened_at = ctx.time.now() - (tonumber(minutes) * 60)
  local state_key = circuit_breaker.build_state_key(ctx.limit_key)
  ctx.dict:set(state_key, "open:" .. tostring(opened_at))
end)

runner:given("^time advances by (%d+) minutes$", function(ctx, minutes)
  ctx.time.advance_time(tonumber(minutes) * 60)
end)

runner:given("^a disabled circuit breaker config$", function(ctx)
  ctx.validation_config = { enabled = false }
end)

runner:given("^circuit breaker is disabled$", function(ctx)
  ctx.config.enabled = false
end)

runner:given("^a config with threshold (%d+) and auto_reset_after_minutes ([%-%d]+)$", function(ctx, threshold, minutes)
  ctx.validation_config = {
    enabled = true,
    spend_rate_threshold_per_minute = tonumber(threshold),
    action = "reject",
    auto_reset_after_minutes = tonumber(minutes),
  }
end)

runner:when("^I validate the circuit breaker config$", function(ctx)
  ctx.ok, ctx.err = circuit_breaker.validate_config(ctx.validation_config)
end)

runner:when("^I check with cost (%d+)$", function(ctx, cost)
  ctx.result = _copy_result(circuit_breaker.check(ctx.dict, ctx.config, ctx.limit_key, tonumber(cost), ctx.time.now()))
end)

runner:when("^I check with cost (%d+) using the set%-failing dict$", function(ctx, cost)
  ctx.result = _copy_result(circuit_breaker.check(ctx.set_fail_dict, ctx.config, ctx.limit_key, tonumber(cost), ctx.time.now()))
end)

runner:when("^I run three checks with costs (%d+), (%d+), and (%d+)$", function(ctx, first, second, third)
  circuit_breaker.check(ctx.dict, ctx.config, ctx.limit_key, tonumber(first), ctx.time.now())
  circuit_breaker.check(ctx.dict, ctx.config, ctx.limit_key, tonumber(second), ctx.time.now())
  ctx.result = _copy_result(circuit_breaker.check(ctx.dict, ctx.config, ctx.limit_key, tonumber(third), ctx.time.now()))
end)

runner:when('^I reset the breaker for limit key "([^"]+)"$', function(ctx, limit_key)
  circuit_breaker.reset(ctx.dict, limit_key)
end)

runner:then_("^validation succeeds$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
end)

runner:then_('^validation fails with error "([^"]+)"$', function(ctx, expected)
  assert.is_nil(ctx.ok)
  assert.equals(expected, ctx.err)
end)

runner:then_('^the breaker result is tripped (%a+) with state "([^"]+)"$', function(ctx, tripped, state)
  assert.equals(tripped == "true", ctx.result.tripped)
  assert.equals(state, ctx.result.state)
end)

runner:then_("^the spend_rate is (%d+)$", function(ctx, spend_rate)
  assert.equals(tonumber(spend_rate), ctx.result.spend_rate)
end)

runner:then_('^the reason is "([^"]+)"$', function(ctx, reason)
  assert.equals(reason, ctx.result.reason)
end)

runner:then_("^the alert field is (%a+)$", function(ctx, alert)
  assert.equals(alert == "true", ctx.result.alert)
end)

runner:then_("^the spend_rate is nil$", function(ctx)
  assert.is_nil(ctx.result.spend_rate)
end)

runner:then_("^org%-2 is not affected and remains closed$", function(ctx)
  local result = circuit_breaker.check(ctx.dict, ctx.config, "org-2", 1, ctx.time.now())
  assert.is_false(result.tripped)
  assert.equals("closed", result.state)
end)

runner:then_('^the state key for limit key "([^"]+)" is cleared$', function(ctx, limit_key)
  local state_key = circuit_breaker.build_state_key(limit_key)
  assert.is_nil(ctx.dict:get(state_key))
end)

runner:then_('^current and previous rate keys for limit key "([^"]+)" are cleared$', function(ctx, limit_key)
  local current_window = _window_start(ctx.time.now())
  local previous_window = current_window - 60

  assert.is_nil(ctx.dict:get(circuit_breaker.build_rate_key(limit_key, current_window)))
  assert.is_nil(ctx.dict:get(circuit_breaker.build_rate_key(limit_key, previous_window)))
end)

runner:feature_file_relative("features/circuit_breaker.feature")
