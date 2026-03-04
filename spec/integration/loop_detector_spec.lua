package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local loop_detector = require("fairvisor.loop_detector")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _copy_result(result)
  return {
    detected = result.detected,
    action = result.action,
    count = result.count,
    retry_after = result.retry_after,
    delay_ms = result.delay_ms,
    reason = result.reason,
  }
end

runner:given("^the nginx mock environment is reset$", function(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.dict = env.dict
end)

runner:given("^a loop detection reject config with threshold 10 and window 60$", function(ctx)
  ctx.config = {
    enabled = true,
    window_seconds = 60,
    threshold_identical_requests = 10,
    action = "reject",
    similarity = "exact",
  }
end)

runner:given('^the fingerprint is built for org "([^"]+)"$', function(ctx, org_id)
  ctx.fingerprint = loop_detector.build_fingerprint(
    "POST",
    "/v1/chat",
    nil,
    nil,
    { ["jwt:org_id"] = org_id }
  )
end)

runner:when("^I run (%d+) loop checks$", function(ctx, count)
  local checks = tonumber(count)
  ctx.results = {}
  for _ = 1, checks do
    ctx.results[#ctx.results + 1] = _copy_result(loop_detector.check(ctx.dict, ctx.config, ctx.fingerprint, 1000))
  end
end)

runner:then_("^the first (%d+) checks report no detection and increasing count$", function(ctx, max_index)
  local limit = tonumber(max_index)
  for i = 1, limit do
    assert.is_false(ctx.results[i].detected)
    assert.equals(i, ctx.results[i].count)
  end
end)

runner:then_("^the (%d+)th check reports reject with retry_after (%d+)$", function(ctx, index, retry_after)
  local i = tonumber(index)
  local result = ctx.results[i]
  assert.is_true(result.detected)
  assert.equals("reject", result.action)
  assert.equals(i, result.count)
  assert.equals(tonumber(retry_after), result.retry_after)
  assert.equals("loop_detected", result.reason)
end)

runner:feature_file_relative("features/loop_detector.feature")
