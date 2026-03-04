package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local shadow_mode = require("fairvisor.shadow_mode")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _copy_decision(decision)
  if decision == nil then
    return nil
  end

  local copy = {}
  for k, v in pairs(decision) do
    copy[k] = v
  end
  return copy
end

runner:given('^a policy with mode "([^"]+)"$', function(ctx, mode)
  ctx.policy = { spec = { mode = mode } }
end)

runner:given("^a policy with empty spec$", function(ctx)
  ctx.policy = { spec = {} }
end)

runner:given("^a policy without spec$", function(ctx)
  ctx.policy = {}
end)

runner:when("^I check whether the policy is shadow$", function(ctx)
  ctx.shadow = shadow_mode.is_shadow(ctx.policy)
end)

runner:then_("^shadow detection returns true$", function(ctx)
  assert.is_true(ctx.shadow)
end)

runner:then_("^shadow detection returns false$", function(ctx)
  assert.is_false(ctx.shadow)
end)

runner:given('^a decision with allowed false reason "([^"]+)" and retry_after (%d+)$',
  function(ctx, reason, retry_after)
    ctx.decision = {
      allowed = false,
      reason = reason,
      retry_after = tonumber(retry_after),
    }
    ctx.before = _copy_decision(ctx.decision)
  end
)

runner:given("^a reject decision with allowed false and no reason$", function(ctx)
  ctx.decision = { allowed = false }
  ctx.before = _copy_decision(ctx.decision)
end)

runner:given('^a decision with allowed true remaining (%d+) and limit (%d+)$', function(ctx, remaining, limit)
  ctx.decision = {
    allowed = true,
    remaining = tonumber(remaining),
    limit = tonumber(limit),
  }
  ctx.before = _copy_decision(ctx.decision)
end)

runner:given("^a nil decision$", function(ctx)
  ctx.decision = nil
end)

runner:given('^policy mode is "([^"]+)"$', function(ctx, mode)
  ctx.policy_mode = mode
end)

runner:when("^I wrap the decision$", function(ctx)
  ctx.result = shadow_mode.wrap(ctx.decision, ctx.policy_mode)
end)

runner:then_("^the same decision table is returned$", function(ctx)
  assert.equals(ctx.decision, ctx.result)
end)

runner:then_("^result allowed is true$", function(ctx)
  assert.is_true(ctx.result.allowed)
end)

runner:then_("^result allowed remains false$", function(ctx)
  assert.is_false(ctx.result.allowed)
end)

runner:then_("^result would_reject is true$", function(ctx)
  assert.is_true(ctx.result.would_reject)
end)

runner:then_("^result would_reject is false$", function(ctx)
  assert.is_false(ctx.result.would_reject)
end)

runner:then_('^result mode is "([^"]+)"$', function(ctx, mode)
  assert.equals(mode, ctx.result.mode)
end)

runner:then_('^result action is "([^"]+)"$', function(ctx, action)
  assert.equals(action, ctx.result.action)
end)

runner:then_("^result mode is nil$", function(ctx)
  assert.is_nil(ctx.result.mode)
end)

runner:then_('^original action is "([^"]+)"$', function(ctx, action)
  assert.equals(action, ctx.result.original_action)
end)

runner:then_('^original reason is "([^"]+)"$', function(ctx, reason)
  assert.equals(reason, ctx.result.original_reason)
end)

runner:then_("^original reason is nil$", function(ctx)
  assert.is_nil(ctx.result.original_reason)
end)

runner:then_("^result reason is nil$", function(ctx)
  assert.is_nil(ctx.result.reason)
end)

runner:then_('^result reason remains "([^"]+)"$', function(ctx, reason)
  assert.equals(reason, ctx.result.reason)
end)

runner:then_("^original retry_after is (%d+)$", function(ctx, retry_after)
  assert.equals(tonumber(retry_after), ctx.result.original_retry_after)
end)

runner:then_("^original retry_after is nil$", function(ctx)
  assert.is_nil(ctx.result.original_retry_after)
end)

runner:then_("^result retry_after is nil$", function(ctx)
  assert.is_nil(ctx.result.retry_after)
end)

runner:then_("^result retry_after remains (%d+)$", function(ctx, retry_after)
  assert.equals(tonumber(retry_after), ctx.result.retry_after)
end)

runner:then_("^remaining and limit are preserved$", function(ctx)
  assert.equals(ctx.before.remaining, ctx.result.remaining)
  assert.equals(ctx.before.limit, ctx.result.limit)
end)

runner:then_("^wrap returns nil$", function(ctx)
  assert.is_nil(ctx.result)
end)

runner:given('^a counter key "([^"]+)"$', function(ctx, key)
  ctx.key = key
end)

runner:given("^a nil counter key$", function(ctx)
  ctx.key = nil
end)

runner:when("^I build the shadow counter key$", function(ctx)
  ctx.shadow_key, ctx.shadow_key_err = shadow_mode.shadow_key(ctx.key)
end)

runner:then_('^shadow key is "([^"]+)"$', function(ctx, expected)
  assert.equals(expected, ctx.shadow_key)
end)

runner:then_("^shadow_key returns nil and error$", function(ctx)
  assert.is_nil(ctx.shadow_key)
  assert.is_string(ctx.shadow_key_err)
  assert.is_true(#ctx.shadow_key_err > 0)
end)

runner:feature_file_relative("features/shadow_mode.feature")
