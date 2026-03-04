package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local cost_budget = require("fairvisor.cost_budget")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _copy_result(result)
  return {
    allowed = result.allowed,
    action = result.action,
    budget_remaining = result.budget_remaining,
    usage_percent = result.usage_percent,
    warning = result.warning,
    delay_ms = result.delay_ms,
    reason = result.reason,
    retry_after = result.retry_after,
  }
end

runner:given("^the nginx mock environment is reset$", function(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.dict = env.dict
  ctx.time = env.time
end)

runner:given("^a validated daily cost budget with budget (%d+) fixed cost (%d+) and reject at 100$", function(ctx, budget, fixed_cost)
  ctx.config = {
    algorithm = "cost_based",
    budget = tonumber(budget),
    period = "1d",
    cost_key = "fixed",
    fixed_cost = tonumber(fixed_cost),
    default_cost = 1,
    staged_actions = {
      { threshold_percent = 100, action = "reject" },
    },
  }

  local ok, err = cost_budget.validate_config(ctx.config)
  assert.is_true(ok, err)
end)

runner:given("^a validated five%-minute cost budget with budget (%d+) fixed cost (%d+) and reject at 100$",
function(ctx, budget, fixed_cost)
  ctx.config = {
    algorithm = "cost_based",
    budget = tonumber(budget),
    period = "5m",
    cost_key = "fixed",
    fixed_cost = tonumber(fixed_cost),
    default_cost = 1,
    staged_actions = {
      { threshold_percent = 100, action = "reject" },
    },
  }

  local ok, err = cost_budget.validate_config(ctx.config)
  assert.is_true(ok, err)
end)

runner:given("^a validated daily staged budget with warn at (%d+) throttle at (%d+) delay (%d+) and reject at 100$",
  function(ctx, warn_threshold, throttle_threshold, delay_ms)
    ctx.config = {
      algorithm = "cost_based",
      budget = 100,
      period = "1d",
      cost_key = "fixed",
      fixed_cost = 1,
      default_cost = 1,
      staged_actions = {
        { threshold_percent = tonumber(warn_threshold), action = "warn" },
        { threshold_percent = tonumber(throttle_threshold), action = "throttle", delay_ms = tonumber(delay_ms) },
        { threshold_percent = 100, action = "reject" },
      },
    }

    local ok, err = cost_budget.validate_config(ctx.config)
    assert.is_true(ok, err)
  end
)

runner:given("^the request key is \"([^\"]+)\"$", function(ctx, key)
  ctx.key = key
end)

runner:given("^time is set to ([%d%.]+)$", function(ctx, now)
  ctx.time.set_time(tonumber(now))
end)

runner:given("^I consume (%d+) checks with cost (%d+)$", function(ctx, count, cost)
  for _ = 1, tonumber(count) do
    cost_budget.check(ctx.dict, ctx.key, ctx.config, tonumber(cost), ctx.time.now())
  end
end)

runner:when("^I run one check with cost (%d+)$", function(ctx, cost)
  ctx.result = _copy_result(cost_budget.check(ctx.dict, ctx.key, ctx.config, tonumber(cost), ctx.time.now()))
end)

runner:when("^I run checks with costs (%d+), (%d+), (%d+), (%d+)$", function(ctx, a, b, c, d)
  ctx.results = {
    _copy_result(cost_budget.check(ctx.dict, ctx.key, ctx.config, tonumber(a), ctx.time.now())),
    _copy_result(cost_budget.check(ctx.dict, ctx.key, ctx.config, tonumber(b), ctx.time.now())),
    _copy_result(cost_budget.check(ctx.dict, ctx.key, ctx.config, tonumber(c), ctx.time.now())),
    _copy_result(cost_budget.check(ctx.dict, ctx.key, ctx.config, tonumber(d), ctx.time.now())),
  }
end)

runner:then_("^the check is allowed with remaining (%d+)$", function(ctx, remaining)
  assert.is_true(ctx.result.allowed)
  assert.equals(tonumber(remaining), ctx.result.budget_remaining)
end)

runner:then_("^the check is rejected with reason \"([^\"]+)\"$", function(ctx, reason)
  assert.is_false(ctx.result.allowed)
  assert.equals("reject", ctx.result.action)
  assert.equals(reason, ctx.result.reason)
end)

runner:then_("^the actions are \"([^\"]+)\", \"([^\"]+)\", \"([^\"]+)\", \"([^\"]+)\"$",
  function(ctx, first, second, third, fourth)
    assert.equals(first, ctx.results[1].action)
    assert.equals(second, ctx.results[2].action)
    assert.equals(third, ctx.results[3].action)
    assert.equals(fourth, ctx.results[4].action)
  end
)

runner:then_("^the second result has warning true$", function(ctx)
  assert.is_true(ctx.results[2].warning)
end)

runner:then_("^the third result has delay_ms (%d+)$", function(ctx, delay_ms)
  assert.equals(tonumber(delay_ms), ctx.results[3].delay_ms)
end)

runner:then_("^the fourth result is rejected with budget remaining 0$", function(ctx)
  assert.is_false(ctx.results[4].allowed)
  assert.equals(0, ctx.results[4].budget_remaining)
end)

runner:given("^time advances by ([%d%.]+) seconds$", function(ctx, seconds)
  ctx.time.advance_time(tonumber(seconds))
end)

runner:feature_file_relative("features/cost_budget.feature")
