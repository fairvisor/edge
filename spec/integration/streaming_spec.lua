package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local reconcile_calls = {}

package.loaded["fairvisor.llm_limiter"] = {
  reconcile = function(_, key, _, estimated_total, actual_total)
    reconcile_calls[#reconcile_calls + 1] = {
      key = key,
      estimated_total = estimated_total,
      actual_total = actual_total,
    }
    return {
      refunded = 0,
      estimated = estimated_total,
      actual = actual_total,
    }
  end,
}

package.loaded["fairvisor.streaming"] = nil
local streaming = require("fairvisor.streaming")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _mk_delta_event(tokens)
  local content = string.rep("y", tonumber(tokens) * 4)
  return 'data: {"choices":[{"delta":{"content":"' .. content .. '"}}]}\n\n'
end

runner:given("^the nginx integration mock environment is reset$", function(ctx)
  local env = mock_ngx.setup_ngx()
  _G.ngx.ctx = {}
  _G.ngx.shared.fairvisor_counters = env.dict
  _G.ngx.log = function()
  end
  reconcile_calls = {}

  ctx.config = {
    max_completion_tokens = 100,
    streaming = {
      enabled = true,
      enforce_mid_stream = true,
      buffer_tokens = 100,
      on_limit_exceeded = "graceful_close",
      include_partial_usage = true,
    },
  }

  ctx.request_context = {
    body = '{"stream":true}',
    headers = {
      Accept = "text/event-stream",
    },
  }

  ctx.reservation = {
    key = "llm:tenant-42",
    estimated_total = 5000,
    prompt_tokens = 40,
    is_shadow = false,
  }
end)

runner:when("^I initialize streaming for the request$", function(ctx)
  ctx.stream_ctx = streaming.init_stream(ctx.config, ctx.request_context, ctx.reservation)
end)

runner:when("^I process two chunks with (%d+) and (%d+) completion tokens$", function(ctx, first_tokens, second_tokens)
  local first = _mk_delta_event(tonumber(first_tokens))
  local second = _mk_delta_event(tonumber(second_tokens))

  ctx.out1 = streaming.body_filter(first, false)
  ctx.out2 = streaming.body_filter(second, false)
end)

runner:when("^I process one chunk with (%d+) completion tokens then DONE$", function(ctx, tokens)
  local first = _mk_delta_event(tonumber(tokens))

  ctx.out1 = streaming.body_filter(first, false)
  ctx.out2 = streaming.body_filter("data: [DONE]\n\n", false)
end)

runner:then_("^TK%-005 truncates with length finish reason and done marker$", function(ctx)
  assert.matches('finish_reason":"length"', ctx.out2)
  assert.matches('data: %[DONE%]\n\n$', ctx.out2)
  assert.is_true(ctx.stream_ctx.truncated)
end)

runner:then_("^TK%-004 completes stream and reconciles once$", function(ctx)
  assert.matches('^data: %{"choices":%[%{"delta":%{"content":"y+"%}%}%]%}%\n\n$', ctx.out1)
  assert.equals("data: [DONE]\n\n", ctx.out2)
  assert.equals(1, #reconcile_calls)
  assert.equals(60, reconcile_calls[1].actual_total)
end)

runner:feature([[
Feature: Streaming enforcement integration flows
  Rule: Golden streaming scenarios
    Scenario: TK-004 Streaming Success
      Given the nginx integration mock environment is reset
      When I initialize streaming for the request
      And I process one chunk with 20 completion tokens then DONE
      Then TK-004 completes stream and reconciles once

    Scenario: TK-005 Mid-Stream Truncation
      Given the nginx integration mock environment is reset
      When I initialize streaming for the request
      And I process two chunks with 60 and 60 completion tokens
      Then TK-005 truncates with length finish reason and done marker
]])
