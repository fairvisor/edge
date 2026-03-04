package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local mock_cjson_safe = require("helpers.mock_cjson_safe")
mock_cjson_safe.install()

local cost_extractor = require("fairvisor.cost_extractor")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local runner = gherkin.new({ describe = describe, context = context, it = it })

runner:given("^the nginx mock environment is reset$", function(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.dict = env.dict
  ctx.time = env.time
end)

runner:given("^a validated response cost config$", function(ctx)
  ctx.config = {
    json_paths = { "$.usage" },
    max_parseable_body_bytes = 1048576,
    max_stream_buffer_bytes = 65536,
    max_parse_time_ms = 2,
    fallback = "estimator_with_audit_flag",
  }
  local ok, err = cost_extractor.validate_config(ctx.config)
  assert.is_true(ok, err)
end)

runner:given("^llm_limiter reconcile spy is installed$", function(ctx)
  ctx.calls = {}
  package.loaded["fairvisor.llm_limiter"] = {
    reconcile = function(_dict, key, _config, estimated_total, actual_total, now)
      ctx.calls[#ctx.calls + 1] = {
        key = key,
        estimated_total = estimated_total,
        actual_total = actual_total,
        now = now,
      }
      return true
    end,
  }
end)

runner:given("^response body usage total is (%d+) prompt (%d+) completion (%d+)$", function(ctx, total, prompt, completion)
  ctx.body = "{\"usage\":{\"total_tokens\":" .. total .. ",\"prompt_tokens\":" .. prompt .. ",\"completion_tokens\":" .. completion .. "}}"
end)

runner:given("^reservation estimated total is (%d+) with key ([^ ]+)$", function(ctx, estimated_total, key)
  ctx.reservation = {
    estimated_total = tonumber(estimated_total),
    key = key,
  }
end)

runner:given("^reconcile now is ([%d%.]+)$", function(ctx, now)
  ctx.now = tonumber(now)
end)

runner:when("^I extract and reconcile response cost$", function(ctx)
  ctx.usage, ctx.err, ctx.details = cost_extractor.extract_from_response(ctx.body, ctx.config)
  assert.is_nil(ctx.err)
  assert.is_nil(ctx.details)

  ctx.reconcile = cost_extractor.reconcile_response(
    ctx.usage,
    ctx.reservation,
    ctx.dict,
    ctx.config,
    ctx.now
  )
end)

runner:then_("^reconcile reports actual (%d+) estimated (%d+) refunded (%d+)$", function(ctx, actual, estimated, refunded)
  assert.equals(tonumber(actual), ctx.reconcile.actual_total)
  assert.equals(tonumber(estimated), ctx.reconcile.estimated_total)
  assert.equals(tonumber(refunded), ctx.reconcile.refunded)
  assert.is_false(ctx.reconcile.cost_source_fallback)
end)

runner:then_("^reconcile ratio is approximately ([%d%.]+)$", function(ctx, ratio)
  assert.is_true(math.abs(ctx.reconcile.estimation_error_ratio - tonumber(ratio)) < 0.001)
end)

runner:then_("^llm_limiter reconcile is called (%d+) time$", function(ctx, count)
  assert.equals(tonumber(count), #ctx.calls)
end)

runner:feature([[
Feature: Cost extractor integration behavior
  Rule: Extraction and refund reconciliation
    Scenario: refunds unused reserved tokens using parsed response usage
      Given the nginx mock environment is reset
      And a validated response cost config
      And llm_limiter reconcile spy is installed
      And response body usage total is 2350 prompt 1500 completion 850
      And reservation estimated total is 3000 with key tb:llm:user-1
      And reconcile now is 1005.5
      When I extract and reconcile response cost
      Then reconcile reports actual 2350 estimated 3000 refunded 650
      And reconcile ratio is approximately 1.277
      And llm_limiter reconcile is called 1 time

    Scenario: does not call reconcile when actual exceeds estimate
      Given the nginx mock environment is reset
      And a validated response cost config
      And llm_limiter reconcile spy is installed
      And response body usage total is 2500 prompt 2000 completion 500
      And reservation estimated total is 2000 with key tb:llm:user-2
      And reconcile now is 1006.0
      When I extract and reconcile response cost
      Then reconcile reports actual 2500 estimated 2000 refunded 0
      And reconcile ratio is approximately 0.8
      And llm_limiter reconcile is called 0 time
]])
