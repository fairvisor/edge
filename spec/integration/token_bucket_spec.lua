package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local token_bucket = require("fairvisor.token_bucket")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _copy_result(r)
  return { allowed = r.allowed, remaining = r.remaining, limit = r.limit, retry_after = r.retry_after }
end

runner:given("^the nginx mock environment is reset$", function(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.dict = env.dict
  ctx.time = env.time
end)

runner:given("^a token bucket with (%d+) tokens per second and burst (%d+)$", function(ctx, rps, burst)
  ctx.config = {
    algorithm = "token_bucket",
    tokens_per_second = tonumber(rps),
    burst = tonumber(burst),
    cost_source = "fixed",
    fixed_cost = 1,
    default_cost = 1,
  }
end)

runner:given("^a token bucket with (%d+) tokens per second, burst (%d+), and fixed cost (%d+)$",
  function(ctx, rps, burst, fixed_cost)
    ctx.config = {
      algorithm = "token_bucket",
      tokens_per_second = tonumber(rps),
      burst = tonumber(burst),
      cost_source = "fixed",
      fixed_cost = tonumber(fixed_cost),
      default_cost = 1,
    }
  end
)

runner:given("^the request key is \"([^\"]+)\"$", function(ctx, key)
  ctx.key = key
end)

runner:given("^I consume (%d+) requests with cost (%d+)$", function(ctx, count, cost)
  local consume_count = tonumber(count)
  local consume_cost = tonumber(cost)

  for _ = 1, consume_count do
    token_bucket.check(ctx.dict, ctx.key, ctx.config, consume_cost)
  end
end)

runner:given("^I consume (%d+) requests with default cost$", function(ctx, count)
  local consume_count = tonumber(count)

  for _ = 1, consume_count do
    token_bucket.check(ctx.dict, ctx.key, ctx.config, 1)
  end
end)

runner:given("^time advances by ([%d%.]+) seconds$", function(ctx, seconds)
  ctx.time.advance_time(tonumber(seconds))
end)

runner:when("^I run (%d+) requests with cost (%d+)$", function(ctx, count, cost)
  local run_count = tonumber(count)
  local run_cost = tonumber(cost)

  ctx.results = {}
  for _ = 1, run_count do
    ctx.results[#ctx.results + 1] = _copy_result(token_bucket.check(ctx.dict, ctx.key, ctx.config, run_cost))
  end
end)

runner:when("^I run (%d+) requests with default cost$", function(ctx, count)
  local run_count = tonumber(count)

  ctx.results = {}
  for _ = 1, run_count do
    ctx.results[#ctx.results + 1] = _copy_result(token_bucket.check(ctx.dict, ctx.key, ctx.config, 1))
  end
end)

runner:when("^I run one request with key \"([^\"]+)\" and default cost$", function(ctx, key)
  ctx.results = { _copy_result(token_bucket.check(ctx.dict, key, ctx.config, 1)) }
end)

runner:then_("^all requests are allowed with remaining tokens: ([%d, ]+)$", function(ctx, values_csv)
  local index = 1
  for expected in string.gmatch(values_csv, "%d+") do
    local result = ctx.results[index]
    assert.is_true(result.allowed)
    assert.equals(tonumber(expected), result.remaining)
    assert.equals(ctx.config.burst, result.limit)
    index = index + 1
  end
end)

runner:then_("^the next request is rejected with retry_after (%d+)$", function(ctx, retry_after)
  local rejected = token_bucket.check(ctx.dict, ctx.key, ctx.config, 1)
  assert.is_false(rejected.allowed)
  assert.equals(0, rejected.remaining)
  assert.equals(ctx.config.burst, rejected.limit)
  assert.equals(tonumber(retry_after), rejected.retry_after)
end)

runner:then_("^the request is rejected$", function(ctx)
  local result = ctx.results[1]
  assert.is_false(result.allowed)
end)

runner:then_("^the request is allowed with remaining tokens (%d+)$", function(ctx, remaining)
  local result = ctx.results[1]
  assert.is_true(result.allowed)
  assert.equals(tonumber(remaining), result.remaining)
end)

runner:feature_file_relative("features/token_bucket.feature")
