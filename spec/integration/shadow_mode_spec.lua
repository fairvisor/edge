package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local shadow_mode = require("fairvisor.shadow_mode")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

runner:given('^a policy mode "([^"]+)"$', function(ctx, mode)
  ctx.policy_mode = mode
end)

runner:given('^an enforcement decision with allowed false reason "([^"]+)" and retry_after (%d+)$',
  function(ctx, reason, retry_after)
    ctx.decision = {
      allowed = false,
      reason = reason,
      retry_after = tonumber(retry_after),
      remaining = 0,
      limit = 100,
    }
  end
)

runner:given('^an enforcement decision with allowed true remaining (%d+) and limit (%d+)$', function(ctx, remaining, limit)
  ctx.decision = {
    allowed = true,
    remaining = tonumber(remaining),
    limit = tonumber(limit),
  }
end)

runner:given('^a rule counter key "([^"]+)"$', function(ctx, key)
  ctx.key = key
end)

runner:when("^the rule engine applies shadow key namespacing$", function(ctx)
  if shadow_mode.is_shadow({ spec = { mode = ctx.policy_mode } }) then
    ctx.effective_key = shadow_mode.shadow_key(ctx.key)
  else
    ctx.effective_key = ctx.key
  end
end)

runner:when("^the rule engine finalizes the decision with shadow wrapping$", function(ctx)
  ctx.result = shadow_mode.wrap(ctx.decision, ctx.policy_mode)
end)

runner:then_('^effective key is "([^"]+)"$', function(ctx, expected)
  assert.equals(expected, ctx.effective_key)
end)

runner:then_("^the finalized result is allowed$", function(ctx)
  assert.is_true(ctx.result.allowed)
end)

runner:then_("^the finalized result is rejected$", function(ctx)
  assert.is_false(ctx.result.allowed)
end)

runner:then_("^finalized mode is shadow$", function(ctx)
  assert.equals("shadow", ctx.result.mode)
end)

runner:then_("^would_reject is true$", function(ctx)
  assert.is_true(ctx.result.would_reject)
end)

runner:then_("^would_reject is false$", function(ctx)
  assert.is_false(ctx.result.would_reject)
end)

runner:then_('^original reason is "([^"]+)"$', function(ctx, reason)
  assert.equals(reason, ctx.result.original_reason)
end)

runner:then_("^retry_after is cleared$", function(ctx)
  assert.is_nil(ctx.result.retry_after)
end)

runner:then_('^finalized reason remains "([^"]+)"$', function(ctx, reason)
  assert.equals(reason, ctx.result.reason)
end)

runner:feature_file_relative("features/shadow_mode.feature")
