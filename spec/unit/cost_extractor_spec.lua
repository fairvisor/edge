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
  package.loaded["fairvisor.llm_limiter"] = nil
end)

runner:given("^a valid response cost config$", function(ctx)
  ctx.config = {
    json_paths = { "$.usage" },
    max_parseable_body_bytes = 1048576,
    max_stream_buffer_bytes = 65536,
    max_parse_time_ms = 2,
    fallback = "estimator_with_audit_flag",
  }
end)

runner:given('^response body is "([^"]+)"$', function(ctx, body)
  ctx.body = body
end)

runner:given("^response body has usage prompt (%d+) completion (%d+) total (%d+)$", function(ctx, prompt, completion, total)
  ctx.body = "{\"usage\":{\"prompt_tokens\":" .. prompt .. ",\"completion_tokens\":" .. completion .. ",\"total_tokens\":" .. total .. "}}"
end)

runner:given("^response body has usage prompt (%d+) completion (%d+) without total$", function(ctx, prompt, completion)
  ctx.body = "{\"usage\":{\"prompt_tokens\":" .. prompt .. ",\"completion_tokens\":" .. completion .. "}}"
end)

runner:given("^response body has no usage$", function(ctx)
  ctx.body = "{\"result\":\"ok\"}"
end)

runner:given("^response body is larger than max_parseable_body_bytes$", function(ctx)
  ctx.config.max_parseable_body_bytes = 10
  ctx.body = string.rep("x", 11)
end)

runner:given("^custom json_path is data usage$", function(ctx)
  ctx.config.json_paths = { "$.data.usage" }
  ctx.body = "{\"data\":{\"usage\":{\"total_tokens\":100}}}"
end)

runner:given("^custom json_path is data usage total only$", function(ctx)
  ctx.config.json_paths = { "$.data.usage.total_tokens" }
  ctx.body = "{\"data\":{\"usage\":{\"total_tokens\":120}}}"
end)

runner:given("^ngx now reports slow parse exceeding max_parse_time_ms$", function(ctx)
  local t = 1000.0
  local calls = 0
  ngx.now = function()
    calls = calls + 1
    if calls == 1 then
      return t
    end
    return t + 0.010
  end
  ctx.body = "{\"usage\":{\"total_tokens\":10}}"
end)

runner:given("^SSE final event data has no usage$", function(ctx)
  ctx.event_data = "{\"done\":true}"
end)

runner:given("^SSE final event data has usage prompt (%d+) completion (%d+) total (%d+)$", function(ctx, prompt, completion, total)
  ctx.event_data = "{\"usage\":{\"prompt_tokens\":" .. prompt
    .. ",\"completion_tokens\":" .. completion .. ",\"total_tokens\":" .. total .. "}}"
end)

runner:given("^reservation estimated total is (%d+) and key is ([^ ]+)$", function(ctx, estimated_total, key)
  ctx.reservation = {
    estimated_total = tonumber(estimated_total),
    key = key,
  }
end)

runner:given("^reservation is not a table$", function(ctx)
  ctx.reservation = 123
end)

runner:given("^extraction actual total is (%d+)$", function(ctx, actual_total)
  ctx.extraction_result = {
    total_tokens = tonumber(actual_total),
  }
end)

runner:given("^llm_limiter reconcile stub is installed$", function(ctx)
  ctx.reconcile_calls = {}
  package.loaded["fairvisor.llm_limiter"] = {
    reconcile = function(_dict, key, _config, estimated_total, actual_total, now)
      ctx.reconcile_calls[#ctx.reconcile_calls + 1] = {
        key = key,
        estimated_total = estimated_total,
        actual_total = actual_total,
        now = now,
      }
      return true
    end,
  }
end)

runner:given("^reconcile now is ([%d%.]+)$", function(ctx, now)
  ctx.reconcile_now = tonumber(now)
end)

runner:given("^config has defaults only$", function(ctx)
  ctx.config = {}
end)

runner:given("^config is not a table$", function(ctx)
  ctx.config = "not a table"
end)

runner:given("^config json_paths is empty$", function(ctx)
  ctx.config = {
    json_paths = {},
  }
end)

runner:given("^config json_paths contains empty string$", function(ctx)
  ctx.config = {
    json_paths = { "$.usage", "" },
  }
end)

runner:when("^I validate cost extractor config$", function(ctx)
  ctx.ok, ctx.err = cost_extractor.validate_config(ctx.config)
end)

runner:when("^I extract usage from response$", function(ctx)
  ctx.usage, ctx.err, ctx.details = cost_extractor.extract_from_response(ctx.body, ctx.config)
end)

runner:when("^I extract usage from SSE final event$", function(ctx)
  ctx.sse_usage = cost_extractor.extract_from_sse_final(ctx.event_data)
end)

runner:when("^I reconcile extraction result$", function(ctx)
  ctx.reconcile, ctx.reconcile_err = cost_extractor.reconcile_response(
    ctx.extraction_result,
    ctx.reservation,
    ctx.dict,
    ctx.config,
    ctx.reconcile_now
  )
end)

runner:when("^I reconcile with missing extraction result$", function(ctx)
  ctx.reconcile = cost_extractor.reconcile_response(nil, ctx.reservation, ctx.dict, ctx.config, ctx.reconcile_now)
end)

runner:when('^I extract json path "([^"]+)" from object with usage total (%d+)$', function(ctx, path, total)
  local obj = { usage = { total_tokens = tonumber(total) } }
  ctx.path_value = cost_extractor.extract_json_path(obj, path)
end)

runner:when('^I extract json path "([^"]*)" from nil object$', function(ctx, path)
  ctx.path_value = cost_extractor.extract_json_path(nil, path)
end)

runner:when('^I extract json path "" from object with usage total (%d+)$', function(ctx, total)
  local obj = { usage = { total_tokens = tonumber(total) } }
  ctx.path_value = cost_extractor.extract_json_path(obj, "")
end)

runner:then_("^validation succeeds$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
end)

runner:then_('^validation fails with error "([^"]+)"$', function(ctx, expected)
  assert.is_nil(ctx.ok)
  assert.equals(expected, ctx.err)
end)

runner:then_("^defaults are applied to response cost config$", function(ctx)
  assert.same({ "$.usage" }, ctx.config.json_paths)
  assert.equals(1048576, ctx.config.max_parseable_body_bytes)
  assert.equals(65536, ctx.config.max_stream_buffer_bytes)
  assert.equals(2, ctx.config.max_parse_time_ms)
  assert.equals("estimator_with_audit_flag", ctx.config.fallback)
end)

runner:then_("^response usage total is (%d+) prompt is (%d+) completion is (%d+)$", function(ctx, total, prompt, completion)
  assert.is_table(ctx.usage)
  assert.equals(tonumber(total), ctx.usage.total_tokens)
  assert.equals(tonumber(prompt), ctx.usage.prompt_tokens)
  assert.equals(tonumber(completion), ctx.usage.completion_tokens)
  assert.is_false(ctx.usage.cost_source_fallback)
end)

runner:then_("^response usage total is (%d+)$", function(ctx, total)
  assert.is_table(ctx.usage)
  assert.equals(tonumber(total), ctx.usage.total_tokens)
end)

runner:then_('^extraction fails with reason "([^"]+)" and fallback true$', function(ctx, expected_reason)
  assert.is_nil(ctx.usage)
  assert.equals(expected_reason, ctx.err)
  assert.is_table(ctx.details)
  assert.is_true(ctx.details.fallback)
end)

runner:then_("^SSE usage total is (%d+) prompt is (%d+) completion is (%d+)$", function(ctx, total, prompt, completion)
  assert.is_table(ctx.sse_usage)
  assert.equals(tonumber(total), ctx.sse_usage.total_tokens)
  assert.equals(tonumber(prompt), ctx.sse_usage.prompt_tokens)
  assert.equals(tonumber(completion), ctx.sse_usage.completion_tokens)
end)

runner:then_("^SSE usage is nil$", function(ctx)
  assert.is_nil(ctx.sse_usage)
end)

runner:then_("^reconcile refunded is (%d+) and ratio is ([%d%.]+)$", function(ctx, refunded, ratio)
  assert.equals(tonumber(refunded), ctx.reconcile.refunded)
  assert.is_true(math.abs(ctx.reconcile.estimation_error_ratio - tonumber(ratio)) < 0.001)
  assert.is_false(ctx.reconcile.cost_source_fallback)
end)

runner:then_("^llm_limiter reconcile is called once with estimated (%d+) and actual (%d+)$", function(ctx, estimated, actual)
  assert.equals(1, #ctx.reconcile_calls)
  assert.equals(tonumber(estimated), ctx.reconcile_calls[1].estimated_total)
  assert.equals(tonumber(actual), ctx.reconcile_calls[1].actual_total)
end)

runner:then_("^fallback reconciliation refunded is 0 and cost_source_fallback true$", function(ctx)
  assert.equals(0, ctx.reconcile.refunded)
  assert.is_true(ctx.reconcile.cost_source_fallback)
end)

runner:then_("^json path value is (%d+)$", function(ctx, expected)
  assert.equals(tonumber(expected), ctx.path_value)
end)

runner:then_("^json path value is nil$", function(ctx)
  assert.is_nil(ctx.path_value)
end)

runner:then_('^reconcile fails with error "([^"]+)"$', function(ctx, expected)
  assert.is_nil(ctx.reconcile)
  assert.equals(expected, ctx.reconcile_err)
end)

runner:feature_file_relative("features/cost_extractor.feature")
