Feature: Shadow mode integration behavior
  Rule: Golden scenario RE-007
    Scenario: RE-007 would-reject is converted to allow with shadow annotations
      Given a policy mode "shadow"
      And an enforcement decision with allowed false reason "rate_limited" and retry_after 1
      And a rule counter key "tb:rule:user-1"
      When the rule engine applies shadow key namespacing
      And the rule engine finalizes the decision with shadow wrapping
      Then effective key is "shadow:tb:rule:user-1"
      And the finalized result is allowed
      And finalized mode is shadow
      And would_reject is true
      And original reason is "rate_limited"
      And retry_after is cleared

  Rule: Enforce behavior remains unchanged
    Scenario: enforce mode preserves key and rejection decision
      Given a policy mode "enforce"
      And an enforcement decision with allowed false reason "rate_limited" and retry_after 1
      And a rule counter key "tb:rule:user-1"
      When the rule engine applies shadow key namespacing
      And the rule engine finalizes the decision with shadow wrapping
      Then effective key is "tb:rule:user-1"
      And the finalized result is rejected
      And finalized reason remains "rate_limited"

    Scenario: shadow mode keeps allow decisions visible as would_reject false
      Given a policy mode "shadow"
      And an enforcement decision with allowed true remaining 50 and limit 100
      And a rule counter key "cb:daily_budget:org-1:1d"
      When the rule engine applies shadow key namespacing
      And the rule engine finalizes the decision with shadow wrapping
      Then effective key is "shadow:cb:daily_budget:org-1:1d"
      And the finalized result is allowed
      And finalized mode is shadow
      And would_reject is false
