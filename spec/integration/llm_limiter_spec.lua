package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local llm_limiter = require("fairvisor.llm_limiter")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _copy_result(result)
  local copied = {}
  for k, v in pairs(result) do
    copied[k] = v
  end
  return copied
end

runner:given("^the nginx mock environment is reset$", function(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.dict = env.dict
  ctx.time = env.time
  ctx.key = "org:tenant-1:model:gpt-4"
end)

runner:given("^an llm limiter config with tokens_per_minute (%d+), burst_tokens (%d+), and default_max_completion (%d+)$",
  function(ctx, tokens_per_minute, burst_tokens, default_max_completion)
    ctx.config = {
      algorithm = "token_bucket_llm",
      tokens_per_minute = tonumber(tokens_per_minute),
      burst_tokens = tonumber(burst_tokens),
      default_max_completion = tonumber(default_max_completion),
      token_source = {
        estimator = "simple_word",
      },
    }
    local ok, err = llm_limiter.validate_config(ctx.config)
    assert.is_true(ok, err)
  end
)

runner:given("^an llm limiter config with tokens_per_minute (%d+), max_prompt_tokens (%d+), and default_max_completion (%d+)$",
  function(ctx, tokens_per_minute, max_prompt_tokens, default_max_completion)
    ctx.config = {
      algorithm = "token_bucket_llm",
      tokens_per_minute = tonumber(tokens_per_minute),
      max_prompt_tokens = tonumber(max_prompt_tokens),
      default_max_completion = tonumber(default_max_completion),
      token_source = {
        estimator = "simple_word",
      },
    }
    local ok, err = llm_limiter.validate_config(ctx.config)
    assert.is_true(ok, err)
  end
)

runner:given("^request context has empty body and max_tokens (%d+)$", function(ctx, max_tokens)
  ctx.request_context = {
    body = "",
    max_tokens = tonumber(max_tokens),
  }
end)

runner:given("^request context has (%d+) prompt characters and max_tokens (%d+)$", function(ctx, chars, max_tokens)
  local content = string.rep("a", tonumber(chars))
  ctx.request_context = {
    body = '{"messages":[{"role":"user","content":"' .. content .. '"}]}',
    max_tokens = tonumber(max_tokens),
  }
end)

runner:when("^I run check at now (%d+)$", function(ctx, now)
  ctx.now = tonumber(now)
  ctx.result = _copy_result(llm_limiter.check(ctx.dict, ctx.key, ctx.config, ctx.request_context, ctx.now))
end)

runner:when("^I reconcile estimated (%d+) with actual (%d+) at now (%d+)$", function(ctx, estimated, actual, now)
  ctx.reconcile_result = llm_limiter.reconcile(
    ctx.dict,
    ctx.key,
    ctx.config,
    tonumber(estimated),
    tonumber(actual),
    tonumber(now)
  )
end)

runner:when("^I run a second check at now (%d+)$", function(ctx, now)
  ctx.result_2 = _copy_result(llm_limiter.check(ctx.dict, ctx.key, ctx.config, ctx.request_context, tonumber(now)))
end)

runner:then_("^the check is allowed with remaining_tpm (%d+)$", function(ctx, remaining_tpm)
  assert.is_true(ctx.result.allowed)
  assert.equals(tonumber(remaining_tpm), ctx.result.remaining_tpm)
end)

runner:then_('^the check is rejected with reason "([^"]+)"$', function(ctx, reason)
  assert.is_false(ctx.result.allowed)
  assert.equals(reason, ctx.result.reason)
end)

runner:then_('^the second check is rejected with reason "([^"]+)"$', function(ctx, reason)
  assert.is_false(ctx.result_2.allowed)
  assert.equals(reason, ctx.result_2.reason)
end)

runner:then_("^the check reserved (%d+) tokens$", function(ctx, reserved)
  assert.equals(tonumber(reserved), ctx.result.reserved)
end)

runner:then_("^the reconcile refunded (%d+) tokens$", function(ctx, refunded)
  assert.equals(tonumber(refunded), ctx.reconcile_result.refunded)
end)

runner:then_("^the second check is allowed$", function(ctx)
  assert.is_true(ctx.result_2.allowed)
end)

runner:feature_file_relative("features/llm_limiter.feature")
