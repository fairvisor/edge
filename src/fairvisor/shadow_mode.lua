local _M = {}

local SHADOW_MODE = "shadow"

function _M.is_shadow(policy)
  return policy ~= nil
    and policy.spec ~= nil
    and policy.spec.mode == SHADOW_MODE
end

function _M.wrap(decision, policy_mode)
  if decision == nil then
    return nil
  end

  if policy_mode ~= SHADOW_MODE then
    return decision
  end

  local was_allowed = decision.allowed

  decision.mode = SHADOW_MODE
  decision.would_reject = not was_allowed
  decision.original_action = was_allowed and "allow" or "reject"
  decision.original_reason = decision.reason
  decision.original_retry_after = decision.retry_after
  decision.allowed = true
  decision.action = "allow"
  -- Client must not see reject headers or Retry-After when we always allow.
  decision.reason = nil
  decision.retry_after = nil

  return decision
end

--- @return string|nil, string|nil namespaced key or nil, error_message
function _M.shadow_key(key)
  if key == nil then
    return nil, "key is required"
  end
  return "shadow:" .. key
end

return _M
