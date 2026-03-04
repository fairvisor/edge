package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local llm_limiter = require("fairvisor.llm_limiter")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local ok_cjson_safe, cjson_safe = pcall(require, "cjson.safe")
if not ok_cjson_safe then
  local ok_cjson, cjson = pcall(require, "cjson")
  if ok_cjson then
    cjson_safe = {
      decode = function(value)
        local ok, decoded = pcall(cjson.decode, value)
        if not ok then
          return nil
        end
        return decoded
      end,
    }
  else
    cjson_safe = {
      decode = function()
        return nil
      end,
    }
  end
end

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _copy_result(result)
  local copied = {}
  for k, v in pairs(result) do
    copied[k] = v
  end
  return copied
end

local function _new_config(overrides)
  local config = {
    algorithm = "token_bucket_llm",
    tokens_per_minute = 10000,
    default_max_completion = 1000,
    token_source = {
      estimator = "simple_word",
    },
  }

  if overrides then
    for k, v in pairs(overrides) do
      config[k] = v
    end
  end

  return config
end

runner:given("^the nginx mock environment is reset$", function(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.dict = env.dict
  ctx.time = env.time
  ctx.key = "org:tenant-1:model:gpt-4"
end)

runner:given("^a valid llm limiter config with tokens_per_minute (%d+)$", function(ctx, tpm)
  ctx.config = _new_config({
    tokens_per_minute = tonumber(tpm),
  })
end)

runner:given("^the config has tokens_per_day (%d+)$", function(ctx, tpd)
  ctx.config.tokens_per_day = tonumber(tpd)
end)

runner:given("^the config has max_prompt_tokens (%d+)$", function(ctx, limit)
  ctx.config.max_prompt_tokens = tonumber(limit)
end)

runner:given("^the config has max_tokens_per_request (%d+)$", function(ctx, limit)
  ctx.config.max_tokens_per_request = tonumber(limit)
end)

runner:given('^the config uses estimator "([^"]+)"$', function(ctx, estimator)
  ctx.config.token_source.estimator = estimator
end)

runner:given("^the config has burst_tokens (%d+)$", function(ctx, burst)
  ctx.config.burst_tokens = tonumber(burst)
end)

runner:given("^the config has default_max_completion (%d+)$", function(ctx, completion)
  ctx.config.default_max_completion = tonumber(completion)
end)

runner:given("^I validate the llm limiter config$", function(ctx)
  ctx.ok, ctx.err = llm_limiter.validate_config(ctx.config)
end)

runner:given("^the llm limiter config is validated$", function(ctx)
  local ok, err = llm_limiter.validate_config(ctx.config)
  assert.is_true(ok, err)
end)

runner:then_("^validation succeeds$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
end)

runner:then_('^validation fails with error "([^"]+)"$', function(ctx, expected)
  assert.is_nil(ctx.ok)
  assert.equals(expected, ctx.err)
end)

runner:then_("^burst_tokens defaults to tokens_per_minute$", function(ctx)
  assert.equals(ctx.config.tokens_per_minute, ctx.config.burst_tokens)
end)

runner:given("^the request body is empty$", function(ctx)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.body = ""
end)

runner:given("^the request body has (%d+) prompt characters in messages$", function(ctx, chars)
  local char_count = tonumber(chars)
  local content = string.rep("a", char_count)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.body = '{"messages":[{"role":"user","content":"' .. content .. '"}]}'
end)

runner:given("^the request body has (%d+) prompt characters and extra metadata (%d+)$", function(ctx, chars, metadata_chars)
  local content = string.rep("a", tonumber(chars))
  local metadata = string.rep("b", tonumber(metadata_chars))
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.body = '{"messages":[{"role":"user","content":"' .. content .. '"}],"metadata":"' .. metadata .. '"}'
end)

runner:given("^the request max_tokens is (%d+)$", function(ctx, max_tokens)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.max_tokens = tonumber(max_tokens)
end)

runner:given("^the request has header X%-Token%-Estimate (%d+)$", function(ctx, estimate)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.headers = ctx.request_context.headers or {}
  ctx.request_context.headers["X-Token-Estimate"] = tostring(estimate)
end)

runner:given('^the request has header "([^"]+)" with value (%d+)$', function(ctx, name, value)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.headers = ctx.request_context.headers or {}
  ctx.request_context.headers[name] = tostring(value)
end)

runner:given("^TPD has already consumed (%d+) tokens at now (%d+)$", function(ctx, consumed, now)
  ctx.now = tonumber(now)
  local date_key = os.date("!%Y%m%d", ctx.now)
  local tpd_key = "tpd:" .. ctx.key .. ":" .. date_key
  ctx.dict:set(tpd_key, tonumber(consumed))
end)

runner:given("^TPD shared dict incr returns an error$", function(ctx)
  ctx.dict.incr = function(_self, _key, _value, _init, _ttl)
    return nil, "simulated_tpd_incr_error"
  end
end)

runner:when("^I run llm check at now (%d+)$", function(ctx, now)
  local run_now = tonumber(now)
  ctx.now = run_now
  ctx.result = _copy_result(llm_limiter.check(ctx.dict, ctx.key, ctx.config, ctx.request_context, run_now))
end)

runner:when("^I run llm check using mocked time$", function(ctx)
  ctx.now = ctx.time.now()
  ctx.result = _copy_result(llm_limiter.check(ctx.dict, ctx.key, ctx.config, ctx.request_context, ctx.now))
end)

runner:when("^I run llm check again at now (%d+)$", function(ctx, now)
  local run_now = tonumber(now)
  ctx.now = run_now
  ctx.result_2 = _copy_result(llm_limiter.check(ctx.dict, ctx.key, ctx.config, ctx.request_context, run_now))
end)

runner:when("^I estimate prompt tokens$", function(ctx)
  ctx.prompt_estimate = llm_limiter.estimate_prompt_tokens(ctx.config, ctx.request_context)
end)

runner:when("^I reconcile estimated (%d+) actual (%d+) at now (%d+)$", function(ctx, estimated, actual, now)
  ctx.reconcile_result = llm_limiter.reconcile(
    ctx.dict,
    ctx.key,
    ctx.config,
    tonumber(estimated),
    tonumber(actual),
    tonumber(now)
  )
end)

runner:when('^I build error response for reason "([^"]+)"$', function(ctx, reason)
  ctx.error_response = llm_limiter.build_error_response(reason, { reason = reason })
  ctx.error_response_decoded = cjson_safe.decode(ctx.error_response)
end)

runner:then_("^check is allowed$", function(ctx)
  assert.is_true(ctx.result.allowed)
end)

runner:then_('^check is rejected with reason "([^"]+)"$', function(ctx, reason)
  assert.is_false(ctx.result.allowed)
  assert.equals(reason, ctx.result.reason)
end)

runner:then_('^second check is rejected with reason "([^"]+)"$', function(ctx, reason)
  assert.is_false(ctx.result_2.allowed)
  assert.equals(reason, ctx.result_2.reason)
end)

runner:then_("^second check is allowed$", function(ctx)
  assert.is_true(ctx.result_2.allowed)
end)

runner:then_("^remaining_tpm is (%d+)$", function(ctx, remaining)
  assert.equals(tonumber(remaining), ctx.result.remaining_tpm)
end)

runner:then_("^remaining_tpd is not set$", function(ctx)
  assert.is_nil(ctx.result.remaining_tpd)
end)

runner:then_("^reserved equals estimated_total (%d+)$", function(ctx, expected)
  assert.equals(tonumber(expected), ctx.result.estimated_total)
  assert.equals(tonumber(expected), ctx.result.reserved)
end)

runner:then_("^estimated_total is (%d+)$", function(ctx, expected)
  assert.equals(tonumber(expected), ctx.result.estimated_total)
end)

runner:then_("^prompt_tokens is (%d+)$", function(ctx, expected)
  assert.equals(tonumber(expected), ctx.result.prompt_tokens)
end)

runner:then_("^remaining_tokens is (%d+)$", function(ctx, expected)
  assert.equals(tonumber(expected), ctx.result.remaining_tokens)
end)

runner:then_("^retry_after is at least (%d+)$", function(ctx, expected)
  assert.is_true(ctx.result.retry_after >= tonumber(expected))
end)

runner:then_("^TPD key value equals (%d+) at now (%d+)$", function(ctx, expected_value, now)
  local date_key = os.date("!%Y%m%d", tonumber(now))
  local tpd_key = "tpd:" .. ctx.key .. ":" .. date_key
  local raw = ctx.dict:get(tpd_key)
  assert.is_not_nil(raw, "TPD key should exist after allowed check (atomic incr)")
  local value = tonumber(raw)
  assert.is_number(value)
  assert.equals(tonumber(expected_value), value, "TPD key should equal consumed tokens (atomic incr)")
end)

runner:then_("^TPM bucket was refunded to full capacity$", function(ctx)
  local tpm_key = "tpm:" .. ctx.key
  local raw = ctx.dict:get(tpm_key)
  assert.is_string(raw, "TPM key should exist after check")
  local sep = string.find(raw, ":", 1, true)
  assert.is_number(sep)
  local tokens = tonumber(string.sub(raw, 1, sep - 1))
  assert.is_number(tokens)
  local burst = ctx.config.burst_tokens or ctx.config.tokens_per_minute
  assert.equals(burst, tokens, "TPM should be refunded to full burst after TPD reject")
end)

runner:then_("^prompt estimate equals (%d+)$", function(ctx, expected)
  assert.equals(tonumber(expected), ctx.prompt_estimate)
end)

runner:then_("^reconcile refunded equals (%d+)$", function(ctx, refunded)
  assert.equals(tonumber(refunded), ctx.reconcile_result.refunded)
end)

runner:then_("^a follow%-up check with estimated_total (%d+) is allowed at now (%d+)$", function(ctx, expected_total, now)
  local result = llm_limiter.check(ctx.dict, ctx.key, ctx.config, {
    body = "",
    max_tokens = tonumber(expected_total),
  }, tonumber(now))
  assert.is_true(result.allowed)
end)

runner:then_("^error response has OpenAI rate limit shape$", function(ctx)
  if ctx.error_response_decoded then
    assert.equals("rate_limit_error", ctx.error_response_decoded.error.type)
    assert.equals("rate_limit_exceeded", ctx.error_response_decoded.error.code)
    assert.is_truthy(string.find(ctx.error_response_decoded.error.message, "Rate limit exceeded", 1, true))
    return
  end

  assert.is_truthy(string.find(ctx.error_response, "\"type\":\"rate_limit_error\"", 1, true))
  assert.is_truthy(string.find(ctx.error_response, "\"code\":\"rate_limit_exceeded\"", 1, true))
  assert.is_truthy(string.find(ctx.error_response, "Rate limit exceeded", 1, true))
end)

runner:feature_file_relative("features/llm_limiter.feature")
