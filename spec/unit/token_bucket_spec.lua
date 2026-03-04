package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local token_bucket = require("fairvisor.token_bucket")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local runner = gherkin.new({ describe = describe, context = context, it = it })

runner:given("^the nginx mock environment is reset$", function(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.dict = env.dict
  ctx.time = env.time
end)

runner:given("^a valid token bucket config with rate (%d+) and burst (%d+)$", function(ctx, rate, burst)
  ctx.config = {
    algorithm = "token_bucket",
    tokens_per_second = tonumber(rate),
    burst = tonumber(burst),
    cost_source = "fixed",
    fixed_cost = 2,
    default_cost = 3,
  }
end)

runner:given("^a config with rps (%d+) and burst (%d+)$", function(ctx, rps, burst)
  ctx.config = {
    algorithm = "token_bucket",
    rps = tonumber(rps),
    burst = tonumber(burst),
  }
end)

runner:given("^a config with tokens_per_second (%d+), rps (%d+), and burst (%d+)$", function(ctx, tps, rps, burst)
  ctx.config = {
    algorithm = "token_bucket",
    tokens_per_second = tonumber(tps),
    rps = tonumber(rps),
    burst = tonumber(burst),
  }
end)

runner:given("^a minimal valid config with tokens_per_second (%d+) and burst (%d+)$", function(ctx, tps, burst)
  ctx.config = {
    algorithm = "token_bucket",
    tokens_per_second = tonumber(tps),
    burst = tonumber(burst),
  }
end)

runner:given("^an invalid non%-table config$", function(ctx)
  ctx.config = "bad"
end)

runner:given('^a config with algorithm "([^"]+)"$', function(ctx, algorithm)
  ctx.config = {
    algorithm = algorithm,
    tokens_per_second = 10,
    burst = 10,
  }
end)

runner:given("^a config missing rate fields and burst (%d+)$", function(ctx, burst)
  ctx.config = {
    algorithm = "token_bucket",
    burst = tonumber(burst),
  }
end)

runner:given("^a config with non%-positive tokens_per_second (%d+) and burst (%d+)$", function(ctx, tps, burst)
  ctx.config = {
    algorithm = "token_bucket",
    tokens_per_second = tonumber(tps),
    burst = tonumber(burst),
  }
end)

runner:given('^a config with tokens_per_second (%d+), burst (%d+), and cost_source "([^"]+)"$',
  function(ctx, tps, burst, cost_source)
    ctx.config = {
      algorithm = "token_bucket",
      tokens_per_second = tonumber(tps),
      burst = tonumber(burst),
      cost_source = cost_source,
    }
  end
)

runner:when("^I validate the config$", function(ctx)
  ctx.ok, ctx.err = token_bucket.validate_config(ctx.config)
end)

runner:then_("^validation succeeds$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
end)

runner:then_('^validation fails with error "([^"]+)"$', function(ctx, expected)
  assert.is_nil(ctx.ok)
  assert.equals(expected, ctx.err)
end)

runner:then_("^tokens_per_second is (%d+)$", function(ctx, expected)
  assert.equals(tonumber(expected), ctx.config.tokens_per_second)
end)

runner:then_("^rps remains (%d+)$", function(ctx, expected)
  assert.equals(tonumber(expected), ctx.config.rps)
end)

runner:then_("^cost defaults are fixed (%d+) and default (%d+)$", function(ctx, fixed_cost, default_cost)
  assert.equals("fixed", ctx.config.cost_source)
  assert.equals(tonumber(fixed_cost), ctx.config.fixed_cost)
  assert.equals(tonumber(default_cost), ctx.config.default_cost)
end)

runner:then_("^header and query cost_source names are accepted$", function()
  local header_config = {
    algorithm = "token_bucket",
    tokens_per_second = 10,
    burst = 10,
    cost_source = "header:X_Weight-1",
  }
  local query_config = {
    algorithm = "token_bucket",
    tokens_per_second = 10,
    burst = 10,
    cost_source = "query:plan_tier",
  }

  assert.is_true(token_bucket.validate_config(header_config))
  assert.is_true(token_bucket.validate_config(query_config))
end)

runner:when('^I build key from rule "([^"]+)" and limit key "([^"]*)"$', function(ctx, rule_name, limit_key)
  ctx.key = token_bucket.build_key(rule_name, limit_key)
end)

runner:then_('^the built key is "([^"]+)"$', function(ctx, expected)
  assert.equals(expected, ctx.key)
end)

runner:given('^a resolve_cost config with source "([^"]+)" fixed_cost (%d+) default_cost (%d+)$',
  function(ctx, source, fixed_cost, default_cost)
    ctx.resolve_config = {
      cost_source = source,
      fixed_cost = tonumber(fixed_cost),
      default_cost = tonumber(default_cost),
    }
  end
)

runner:given('^a validated resolve config with cost_source "([^"]+)" fixed_cost (%d+) default_cost (%d+)$',
  function(ctx, cost_source, fixed_cost, default_cost)
    local config = {
      algorithm = "token_bucket",
      tokens_per_second = 10,
      burst = 10,
      cost_source = cost_source,
      fixed_cost = tonumber(fixed_cost),
      default_cost = tonumber(default_cost),
    }
    local ok, err = token_bucket.validate_config(config)
    assert.is_true(ok, err)
    ctx.resolve_config = config
  end
)

runner:given('^request headers contain "([^"]+)" as "([^"]+)"$', function(ctx, header_name, header_value)
  ctx.request_context = ctx.request_context or { headers = {}, query_params = {} }
  ctx.request_context.headers[header_name] = header_value
end)

runner:given('^request query contains "([^"]+)" as "([^"]+)"$', function(ctx, query_name, query_value)
  ctx.request_context = ctx.request_context or { headers = {}, query_params = {} }
  ctx.request_context.query_params[query_name] = query_value
end)

runner:given("^an empty request context$", function(ctx)
  ctx.request_context = { headers = {}, query_params = {} }
end)

runner:when("^I resolve request cost$", function(ctx)
  ctx.cost = token_bucket.resolve_cost(ctx.resolve_config, ctx.request_context)
end)

runner:then_("^the resolved cost is (%d+)$", function(ctx, expected)
  assert.equals(tonumber(expected), ctx.cost)
end)

local function _new_config(overrides)
  local config = {
    algorithm = "token_bucket",
    tokens_per_second = 100,
    burst = 200,
    cost_source = "fixed",
    fixed_cost = 1,
    default_cost = 1,
  }

  if overrides then
    for k, v in pairs(overrides) do
      config[k] = v
    end
  end

  return config
end

runner:given("^a default runtime token bucket config$", function(ctx)
  ctx.runtime_config = _new_config()
end)

runner:given("^a runtime config with tokens_per_second (%d+) and burst (%d+)$", function(ctx, tps, burst)
  ctx.runtime_config = _new_config({
    tokens_per_second = tonumber(tps),
    burst = tonumber(burst),
  })
end)

runner:given("^a runtime config with fixed_cost (%d+)$", function(ctx, fixed_cost)
  ctx.runtime_config = _new_config({ fixed_cost = tonumber(fixed_cost) })
end)

runner:given("^an unchecked runtime config with tokens_per_second (%d+) and burst (%d+)$", function(ctx, tps, burst)
  ctx.runtime_config = {
    tokens_per_second = tonumber(tps),
    burst = tonumber(burst),
  }
end)

runner:given('^the runtime key is built for rule "([^"]+)" and tenant "([^"]+)"$', function(ctx, rule_name, tenant)
  ctx.runtime_key = token_bucket.build_key(rule_name, tenant)
end)

runner:given('^the runtime key is "([^"]+)"$', function(ctx, key)
  ctx.runtime_key = key
end)

runner:given("^I consume (%d+) runtime checks with cost (%d+)$", function(ctx, count, cost)
  for _ = 1, tonumber(count) do
    token_bucket.check(ctx.dict, ctx.runtime_key, ctx.runtime_config, tonumber(cost))
  end
end)

runner:given("^stored bucket value is malformed$", function(ctx)
  ctx.dict:set(ctx.runtime_key, "malformed")
end)

runner:given("^stored bucket has (%d+) tokens at current time$", function(ctx, tokens)
  ctx.dict:set(ctx.runtime_key, string.format("%.6f:%.6f", tonumber(tokens), ctx.time.now()))
end)

runner:given("^time advances by ([%d%.]+) seconds$", function(ctx, seconds)
  ctx.time.advance_time(tonumber(seconds))
end)

runner:given("^time moves backward by ([%d%.]+) seconds$", function(ctx, seconds)
  ctx.time.set_time(ctx.time.now() - tonumber(seconds))
end)

runner:given("^a counting shared_dict is used$", function(ctx)
  local ops = { get = 0, set = 0 }
  local data = {}
  ctx.ops = ops
  ctx.counting_dict = {
    get = function(_, key)
      ops.get = ops.get + 1
      return data[key]
    end,
    set = function(_, key, value)
      ops.set = ops.set + 1
      data[key] = value
      return true
    end,
  }
end)

runner:given("^a set%-failing shared_dict is used$", function(ctx)
  ctx.fail_set_dict = {
    get = function()
      return nil
    end,
    set = function()
      return nil, "no memory"
    end,
  }
end)

local function _copy_result(r)
  return { allowed = r.allowed, remaining = r.remaining, limit = r.limit, retry_after = r.retry_after }
end

runner:when("^I execute (%d+) runtime checks with cost (%d+)$", function(ctx, count, cost)
  ctx.results = {}
  for _ = 1, tonumber(count) do
    ctx.results[#ctx.results + 1] = _copy_result(token_bucket.check(ctx.dict, ctx.runtime_key, ctx.runtime_config, tonumber(cost)))
  end
end)

runner:when("^I execute one runtime check with cost (%d+)$", function(ctx, cost)
  ctx.result = _copy_result(token_bucket.check(ctx.dict, ctx.runtime_key, ctx.runtime_config, tonumber(cost)))
end)

runner:when("^I execute one runtime check on the counting dict with cost (%d+)$", function(ctx, cost)
  ctx.result = _copy_result(token_bucket.check(ctx.counting_dict, ctx.runtime_key, ctx.runtime_config, tonumber(cost)))
end)

runner:when("^I execute one runtime check on the set%-failing dict with cost (%d+)$", function(ctx, cost)
  ctx.result = _copy_result(token_bucket.check(ctx.fail_set_dict, ctx.runtime_key, ctx.runtime_config, tonumber(cost)))
end)

runner:when("^I execute one runtime check with cost (%d+) and store result as first result$", function(ctx, cost)
  ctx.first_result = token_bucket.check(ctx.dict, ctx.runtime_key, ctx.runtime_config, tonumber(cost))
end)

runner:when("^I execute one runtime check with cost (%d+) and store result as second result$", function(ctx, cost)
  ctx.second_result = token_bucket.check(ctx.dict, ctx.runtime_key, ctx.runtime_config, tonumber(cost))
  ctx.expected_second_remaining = ctx.second_result.remaining
end)

runner:when("^I mutate the first result allowed to false and remaining to (%d+)$", function(ctx, remaining)
  ctx.first_result.allowed = false
  ctx.first_result.remaining = tonumber(remaining)
end)

runner:then_("^the first and second results are different tables$", function(ctx)
  assert.is_not_nil(ctx.first_result)
  assert.is_not_nil(ctx.second_result)
  assert.is_not_equal(ctx.first_result, ctx.second_result)
end)

runner:then_("^the second result remaining is unchanged$", function(ctx)
  assert.equals(ctx.expected_second_remaining, ctx.second_result.remaining)
end)

runner:then_("^all runtime checks are allowed with remaining tokens: ([%d, ]+)$", function(ctx, values)
  local i = 1
  for expected in string.gmatch(values, "%d+") do
    local result = ctx.results[i]
    assert.is_true(result.allowed)
    assert.equals(tonumber(expected), result.remaining)
    assert.equals(ctx.runtime_config.burst, result.limit)
    i = i + 1
  end
end)

runner:then_("^the runtime check is rejected with remaining (%d+) retry_after (%d+) and limit (%d+)$",
  function(ctx, remaining, retry_after, limit)
    assert.is_false(ctx.result.allowed)
    assert.equals(tonumber(remaining), ctx.result.remaining)
    assert.equals(tonumber(retry_after), ctx.result.retry_after)
    assert.equals(tonumber(limit), ctx.result.limit)
  end
)

runner:then_("^the runtime check is allowed with remaining (%d+) and limit (%d+)$", function(ctx, remaining, limit)
  assert.is_true(ctx.result.allowed)
  assert.equals(tonumber(remaining), ctx.result.remaining)
  assert.equals(tonumber(limit), ctx.result.limit)
end)

runner:then_("^the counting dict recorded get (%d+) and set (%d+)$", function(ctx, expected_get, expected_set)
  assert.equals(tonumber(expected_get), ctx.ops.get)
  assert.equals(tonumber(expected_set), ctx.ops.set)
end)

runner:then_("^the runtime decision fields include allowed remaining and limit only$", function(ctx)
  assert.is_not_nil(ctx.result.allowed)
  assert.is_not_nil(ctx.result.remaining)
  assert.is_not_nil(ctx.result.limit)
  assert.is_nil(ctx.result.metric)
  assert.is_nil(ctx.result.reason)
end)

runner:feature_file_relative("features/token_bucket.feature")
