package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local cost_budget = require("fairvisor.cost_budget")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _copy_staged_actions(actions)
  local copied = {}
  for i = 1, #actions do
    local action = actions[i]
    copied[i] = {
      threshold_percent = action.threshold_percent,
      action = action.action,
      delay_ms = action.delay_ms,
    }
  end
  return copied
end

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

local function _default_config(overrides)
  local config = {
    algorithm = "cost_based",
    budget = 1000,
    period = "1d",
    cost_key = "fixed",
    fixed_cost = 1,
    default_cost = 1,
    staged_actions = {
      { threshold_percent = 80, action = "warn" },
      { threshold_percent = 95, action = "throttle", delay_ms = 200 },
      { threshold_percent = 100, action = "reject" },
    },
  }

  if overrides then
    for k, v in pairs(overrides) do
      if k == "staged_actions" then
        config.staged_actions = _copy_staged_actions(v)
      else
        config[k] = v
      end
    end
  end

  return config
end

runner:given("^the nginx mock environment is reset$", function(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.dict = env.dict
  ctx.time = env.time
end)

runner:given("^a default cost budget config$", function(ctx)
  ctx.config = _default_config()
end)

runner:given("^a config with budget (%d+) period \"([^\"]+)\" cost_key \"([^\"]+)\"$", function(ctx, budget, period, cost_key)
  ctx.config = _default_config({
    budget = tonumber(budget),
    period = period,
    cost_key = cost_key,
  })
end)

runner:given("^a config with staged actions thresholds ([%d, ]+)$", function(ctx, thresholds)
  local actions = {}
  for threshold in string.gmatch(thresholds, "%d+") do
    local threshold_number = tonumber(threshold)
    actions[#actions + 1] = {
      threshold_percent = threshold_number,
      action = threshold_number == 100 and "reject" or "warn",
    }
  end
  ctx.config = _default_config({ staged_actions = actions })
end)

runner:given("^a config with duplicate staged action thresholds (%d+) and (%d+)$", function(ctx, threshold_a, threshold_b)
  ctx.config = _default_config({
    staged_actions = {
      { threshold_percent = tonumber(threshold_a), action = "warn" },
      { threshold_percent = tonumber(threshold_b), action = "reject" },
    },
  })
end)

runner:given("^a config missing reject at 100 percent$", function(ctx)
  ctx.config = _default_config({
    staged_actions = {
      { threshold_percent = 80, action = "warn" },
      { threshold_percent = 95, action = "throttle", delay_ms = 200 },
    },
  })
end)

runner:given("^a config with throttle action missing delay_ms$", function(ctx)
  ctx.config = _default_config({
    staged_actions = {
      { threshold_percent = 95, action = "throttle" },
      { threshold_percent = 100, action = "reject" },
    },
  })
end)

runner:given("^a config with non%-table value$", function(ctx)
  ctx.config = "bad"
end)

runner:given("^a config with algorithm \"([^\"]+)\"$", function(ctx, algorithm)
  ctx.config = _default_config({ algorithm = algorithm })
end)

runner:given("^a config with budget (%d+) and default_cost (%d+)$", function(ctx, budget, default_cost)
  ctx.config = _default_config({ budget = tonumber(budget), default_cost = tonumber(default_cost) })
end)

runner:given("^a config with period \"([^\"]+)\"$", function(ctx, period)
  ctx.config = _default_config({ period = period })
end)

runner:given("^a config with invalid cost_key \"([^\"]+)\"$", function(ctx, cost_key)
  ctx.config = _default_config({ cost_key = cost_key })
end)

runner:given("^a config with cost_key fixed and fixed_cost (%d+)$", function(ctx, fixed_cost)
  ctx.config = _default_config({ cost_key = "fixed", fixed_cost = tonumber(fixed_cost) })
end)

runner:given("^a config with empty staged_actions$", function(ctx)
  ctx.config = _default_config({ staged_actions = {} })
end)

runner:when("^I validate the config$", function(ctx)
  ctx.ok, ctx.err = cost_budget.validate_config(ctx.config)
end)

runner:then_("^validation succeeds$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
end)

runner:then_("^validation fails with error \"([^\"]+)\"$", function(ctx, expected)
  assert.is_nil(ctx.ok)
  assert.equals(expected, ctx.err)
end)

runner:then_("^staged actions are sorted ascending as (%d+), (%d+), (%d+)$", function(ctx, first, second, third)
  assert.equals(tonumber(first), ctx.config.staged_actions[1].threshold_percent)
  assert.equals(tonumber(second), ctx.config.staged_actions[2].threshold_percent)
  assert.equals(tonumber(third), ctx.config.staged_actions[3].threshold_percent)
end)

runner:then_("^cost key cache is kind \"([^\"]+)\" and name \"([^\"]*)\"$", function(ctx, kind, name)
  assert.equals(kind, ctx.config._cost_key_kind)
  assert.equals(name ~= "" and name or nil, ctx.config._cost_key_name)
end)

runner:when("^I build key from rule \"([^\"]+)\" and limit key \"([^\"]*)\"$", function(ctx, rule_name, limit_key)
  ctx.built_key = cost_budget.build_key(rule_name, limit_key)
end)

runner:then_("^the built key is \"([^\"]+)\"$", function(ctx, expected)
  assert.equals(expected, ctx.built_key)
end)

runner:given("^a resolve config with cost_key \"([^\"]+)\" fixed_cost (%d+) default_cost (%d+)$",
  function(ctx, cost_key, fixed_cost, default_cost)
    ctx.resolve_config = {
      cost_key = cost_key,
      fixed_cost = tonumber(fixed_cost),
      default_cost = tonumber(default_cost),
    }
  end
)

runner:given("^a validated resolve config with cost_key \"([^\"]+)\" fixed_cost (%d+) default_cost (%d+)$",
  function(ctx, cost_key, fixed_cost, default_cost)
    local config = {
      algorithm = "cost_based",
      budget = 100,
      period = "1d",
      cost_key = cost_key,
      fixed_cost = tonumber(fixed_cost),
      default_cost = tonumber(default_cost),
      staged_actions = {
        { threshold_percent = 100, action = "reject" },
      },
    }

    local ok, err = cost_budget.validate_config(config)
    assert.is_true(ok, err)
    ctx.resolve_config = config
  end
)

runner:given("^request headers contain \"([^\"]+)\" as \"([^\"]+)\"$", function(ctx, header_name, header_value)
  ctx.request_context = ctx.request_context or { headers = {}, query_params = {} }
  ctx.request_context.headers[header_name] = header_value
end)

runner:given("^request query contains \"([^\"]+)\" as \"([^\"]+)\"$", function(ctx, query_name, query_value)
  ctx.request_context = ctx.request_context or { headers = {}, query_params = {} }
  ctx.request_context.query_params[query_name] = query_value
end)

runner:given("^an empty request context$", function(ctx)
  ctx.request_context = { headers = {}, query_params = {} }
end)

runner:when("^I resolve request cost$", function(ctx)
  ctx.resolved_cost = cost_budget.resolve_cost(ctx.resolve_config, ctx.request_context)
end)

runner:then_("^the resolved cost is (%d+)$", function(ctx, expected)
  assert.equals(tonumber(expected), ctx.resolved_cost)
end)

runner:when("^I compute period start for period \"([^\"]+)\" at now ([%d%.]+)$", function(ctx, period, now)
  ctx.period_start, ctx.period_err = cost_budget.compute_period_start(period, tonumber(now))
end)

runner:then_("^the period start is ([%d%.]+)$", function(ctx, expected)
  assert.equals(tonumber(expected), ctx.period_start)
  assert.is_nil(ctx.period_err)
end)

runner:then_("^period start computation fails with \"([^\"]+)\"$", function(ctx, expected)
  assert.is_nil(ctx.period_start)
  assert.equals(expected, ctx.period_err)
end)

runner:given(
  "^a runtime config with budget (%d+) period \"([^\"]+)\"" ..
  " and staged actions (%d+) warn (%d+) throttle (%d+) reject delay (%d+)$",
  function(ctx, budget, period, warn_threshold, throttle_threshold, reject_threshold, delay_ms)
    ctx.runtime_config = _default_config({
      budget = tonumber(budget),
      period = period,
      staged_actions = {
        { threshold_percent = tonumber(warn_threshold), action = "warn" },
        { threshold_percent = tonumber(throttle_threshold), action = "throttle", delay_ms = tonumber(delay_ms) },
        { threshold_percent = tonumber(reject_threshold), action = "reject" },
      },
    })

    local ok, err = cost_budget.validate_config(ctx.runtime_config)
    assert.is_true(ok, err)
  end
)

runner:given("^a runtime config with budget (%d+) period \"([^\"]+)\" and reject at 100$", function(ctx, budget, period)
  ctx.runtime_config = _default_config({
    budget = tonumber(budget),
    period = period,
    staged_actions = {
      { threshold_percent = 100, action = "reject" },
    },
  })

  local ok, err = cost_budget.validate_config(ctx.runtime_config)
  assert.is_true(ok, err)
end)

runner:given("^the runtime key is built for rule \"([^\"]+)\" and tenant \"([^\"]+)\"$", function(ctx, rule_name, tenant)
  ctx.runtime_key = cost_budget.build_key(rule_name, tenant)
end)

runner:given("^the runtime key is \"([^\"]+)\"$", function(ctx, runtime_key)
  ctx.runtime_key = runtime_key
end)

runner:given("^usage is preloaded as (%d+) for current period$", function(ctx, usage)
  local period_start = assert(cost_budget.compute_period_start(ctx.runtime_config.period, ctx.time.now()))
  local full_key = ctx.runtime_key .. ":" .. period_start
  ctx.dict:set(full_key, tonumber(usage))
end)

runner:given("^usage is preloaded as (%d+) at now ([%d%.]+)$", function(ctx, usage, now)
  local now_number = tonumber(now)
  local period_start = assert(cost_budget.compute_period_start(ctx.runtime_config.period, now_number))
  local full_key = ctx.runtime_key .. ":" .. period_start
  ctx.dict:set(full_key, tonumber(usage))
end)

runner:given("^time is set to ([%d%.]+)$", function(ctx, now)
  ctx.time.set_time(tonumber(now))
end)

runner:given("^time advances by ([%d%.]+) seconds$", function(ctx, seconds)
  ctx.time.advance_time(tonumber(seconds))
end)

runner:when("^I run one budget check with cost (%d+)$", function(ctx, cost)
  ctx.runtime_result = _copy_result(cost_budget.check(ctx.dict, ctx.runtime_key, ctx.runtime_config, tonumber(cost), ctx.time.now()))
end)

runner:when("^I run one budget check with cost (%d+) at now ([%d%.]+)$", function(ctx, cost, now)
  ctx.runtime_result = _copy_result(cost_budget.check(ctx.dict, ctx.runtime_key, ctx.runtime_config, tonumber(cost), tonumber(now)))
end)

runner:when("^I run (%d+) budget checks with cost (%d+)$", function(ctx, count, cost)
  ctx.runtime_results = {}
  for _ = 1, tonumber(count) do
    ctx.runtime_results[#ctx.runtime_results + 1] = _copy_result(
      cost_budget.check(ctx.dict, ctx.runtime_key, ctx.runtime_config, tonumber(cost), ctx.time.now())
    )
  end
end)

runner:then_("^the budget check is allowed with action \"([^\"]+)\" remaining (%d+) usage_percent ([%d%.]+)$",
  function(ctx, action, remaining, usage_percent)
    assert.is_true(ctx.runtime_result.allowed)
    assert.equals(action, ctx.runtime_result.action)
    assert.equals(tonumber(remaining), ctx.runtime_result.budget_remaining)
    assert.equals(tonumber(usage_percent), ctx.runtime_result.usage_percent)
  end
)

runner:then_("^the budget check is rejected with reason \"([^\"]+)\" retry_after (%d+) usage_percent ([%d%.]+)$",
  function(ctx, reason, retry_after, usage_percent)
    assert.is_false(ctx.runtime_result.allowed)
    assert.equals("reject", ctx.runtime_result.action)
    assert.equals(reason, ctx.runtime_result.reason)
    assert.equals(tonumber(retry_after), ctx.runtime_result.retry_after)
    assert.near(tonumber(usage_percent), ctx.runtime_result.usage_percent, 0.01)
  end
)

runner:then_("^warning flag is true$", function(ctx)
  assert.is_true(ctx.runtime_result.warning)
end)

runner:then_("^delay_ms is (%d+)$", function(ctx, expected)
  assert.equals(tonumber(expected), ctx.runtime_result.delay_ms)
end)

runner:then_("^the last budget check action is \"([^\"]+)\"$", function(ctx, action)
  local last = ctx.runtime_results[#ctx.runtime_results]
  assert.equals(action, last.action)
end)

runner:then_("^the stored usage for current period is (%d+)$", function(ctx, usage)
  local period_start = assert(cost_budget.compute_period_start(ctx.runtime_config.period, ctx.time.now()))
  local full_key = ctx.runtime_key .. ":" .. period_start
  assert.equals(tonumber(usage), ctx.dict:get(full_key))
end)

runner:then_("^the period key at now ([%d%.]+) stores usage (%d+)$", function(ctx, now, usage)
  local now_number = tonumber(now)
  local period_start = assert(cost_budget.compute_period_start(ctx.runtime_config.period, now_number))
  local full_key = ctx.runtime_key .. ":" .. period_start
  assert.equals(tonumber(usage), ctx.dict:get(full_key))
end)

runner:feature_file_relative("features/cost_budget.feature")
