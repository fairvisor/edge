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

runner:given('^loop detection config has threshold (%d+), window (%d+), and action "([^"]+)"$',
  function(ctx, threshold, window_seconds, action)
    ctx.config = {
      enabled = true,
      window_seconds = tonumber(window_seconds),
      threshold_identical_requests = tonumber(threshold),
      action = action,
      similarity = "exact",
    }
  end
)

runner:given("^loop detection config is disabled$", function(ctx)
  ctx.config = {
    enabled = false,
  }
end)

runner:given('^loop detection config has invalid threshold (%d+)$', function(ctx, threshold)
  ctx.config = {
    enabled = true,
    window_seconds = 60,
    threshold_identical_requests = tonumber(threshold),
    action = "reject",
    similarity = "exact",
  }
end)

runner:given('^loop detection config has unknown action "([^"]+)"$', function(ctx, action)
  ctx.config = {
    enabled = true,
    window_seconds = 60,
    threshold_identical_requests = 10,
    action = action,
    similarity = "exact",
  }
end)

runner:given("^loop detection config is enabled with threshold (%d+) but missing window_seconds$",
  function(ctx, threshold)
    ctx.config = {
      enabled = true,
      threshold_identical_requests = tonumber(threshold),
      action = "reject",
      similarity = "exact",
    }
  end
)

runner:given("^loop detection config is enabled with window (%d+) but missing threshold$",
  function(ctx, window_seconds)
    ctx.config = {
      enabled = true,
      window_seconds = tonumber(window_seconds),
      action = "reject",
      similarity = "exact",
    }
  end
)

runner:given('^the fingerprint is "([^"]+)"$', function(ctx, fingerprint)
  ctx.fingerprint = fingerprint
end)

runner:given('^fingerprint "([^"]+)" has been checked (%d+) times$', function(ctx, fingerprint, count)
  for _ = 1, tonumber(count) do
    loop_detector.check(ctx.dict, ctx.config, fingerprint, 1000)
  end
end)

runner:given("^a dict incr error is simulated$", function(ctx)
  ctx.dict = {
    incr = function()
      return nil, "no memory"
    end,
  }
end)

runner:when("^I validate the loop detection config$", function(ctx)
  ctx.ok, ctx.err = loop_detector.validate_config(ctx.config)
end)

runner:when("^I build the fingerprint once with method POST and path /v1/chat and query model=gpt%-4$", function(ctx)
  ctx.first_fp = loop_detector.build_fingerprint("POST", "/v1/chat", { model = "gpt-4" }, nil, nil)
end)

runner:when("^I build the fingerprint again with method GET and path /v1/chat and query model=gpt%-4$", function(ctx)
  ctx.second_fp = loop_detector.build_fingerprint("GET", "/v1/chat", { model = "gpt-4" }, nil, nil)
end)

runner:when("^I build two fingerprints with same query params in different key order$", function(ctx)
  ctx.first_fp = loop_detector.build_fingerprint("POST", "/v1/chat", { b = "2", a = "1" }, nil, nil)
  ctx.second_fp = loop_detector.build_fingerprint("POST", "/v1/chat", { a = "1", b = "2" }, nil, nil)
end)

runner:when("^I build two fingerprints with different limit key values$", function(ctx)
  ctx.first_fp = loop_detector.build_fingerprint(
    "POST",
    "/v1/chat",
    { model = "gpt-4" },
    nil,
    { ["jwt:org_id"] = "acme" }
  )
  ctx.second_fp = loop_detector.build_fingerprint(
    "POST",
    "/v1/chat",
    { model = "gpt-4" },
    nil,
    { ["jwt:org_id"] = "globex" }
  )
end)

runner:when('^I run one loop check for fingerprint "([^"]+)"$', function(ctx, fingerprint)
  ctx.result = _copy_result(loop_detector.check(ctx.dict, ctx.config, fingerprint, 1000))
end)

runner:then_("^validation succeeds$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
end)

runner:then_('^validation fails with error "([^"]+)"$', function(ctx, err)
  assert.is_nil(ctx.ok)
  assert.equals(err, ctx.err)
end)

runner:then_("^the result reports no detection with count (%d+)$", function(ctx, count)
  assert.is_false(ctx.result.detected)
  assert.equals(tonumber(count), ctx.result.count)
  assert.is_nil(ctx.result.action)
  assert.is_nil(ctx.result.reason)
end)

runner:then_('^the result reports detection with action "([^"]+)" and count (%d+)$', function(ctx, action, count)
  assert.is_true(ctx.result.detected)
  assert.equals(action, ctx.result.action)
  assert.equals(tonumber(count), ctx.result.count)
  assert.equals("loop_detected", ctx.result.reason)
end)

runner:then_("^retry_after equals (%d+)$", function(ctx, retry_after)
  assert.equals(tonumber(retry_after), ctx.result.retry_after)
  assert.is_nil(ctx.result.delay_ms)
end)

runner:then_("^delay_ms equals (%d+)$", function(ctx, delay_ms)
  assert.equals(tonumber(delay_ms), ctx.result.delay_ms)
  assert.is_nil(ctx.result.retry_after)
end)

runner:then_("^the two fingerprints are different$", function(ctx)
  assert.not_equals(ctx.first_fp, ctx.second_fp)
end)

runner:then_("^the two fingerprints are equal$", function(ctx)
  assert.equals(ctx.first_fp, ctx.second_fp)
end)

runner:then_('^fingerprint "([^"]+)" stored count is (%d+)$', function(ctx, fingerprint, count)
  assert.equals(tonumber(count), ctx.dict:get("loop:" .. fingerprint))
end)

runner:feature_file_relative("features/loop_detector.feature")
