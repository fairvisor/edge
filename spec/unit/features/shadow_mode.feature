Feature: Shadow mode decision wrapping
  Rule: Policy mode detection
    Scenario: AC-5 is_shadow detects shadow mode
      Given a policy with mode "shadow"
      When I check whether the policy is shadow
      Then shadow detection returns true

    Scenario: AC-6 is_shadow returns false for enforce mode
      Given a policy with mode "enforce"
      When I check whether the policy is shadow
      Then shadow detection returns false

    Scenario: AC-7 is_shadow defaults to false for missing mode
      Given a policy with empty spec
      When I check whether the policy is shadow
      Then shadow detection returns false

    Scenario: AC-8 is_shadow handles missing spec
      Given a policy without spec
      When I check whether the policy is shadow
      Then shadow detection returns false

  Rule: Shadow wrapping behavior
    Scenario: AC-1 shadow mode forces ALLOW on would-reject
      Given a decision with allowed false reason "rate_limited" and retry_after 5
      And policy mode is "shadow"
      When I wrap the decision
      Then the same decision table is returned
      And result allowed is true
      And result action is "allow"
      And result would_reject is true
      And result mode is "shadow"

    Scenario: AC-2 shadow mode preserves original reject details
      Given a decision with allowed false reason "rate_limited" and retry_after 5
      And policy mode is "shadow"
      When I wrap the decision
      Then original action is "reject"
      And original reason is "rate_limited"
      And original retry_after is 5

    Scenario: AC-3 shadow mode annotates allowed decisions
      Given a decision with allowed true remaining 50 and limit 100
      And policy mode is "shadow"
      When I wrap the decision
      Then result allowed is true
      And result action is "allow"
      And result would_reject is false
      And result mode is "shadow"
      And original action is "allow"
      And remaining and limit are preserved

    Scenario: AC-4 enforce mode passes through unchanged
      Given a decision with allowed false reason "rate_limited" and retry_after 5
      And policy mode is "enforce"
      When I wrap the decision
      Then the same decision table is returned
      And result allowed remains false
      And result reason remains "rate_limited"
      And result retry_after remains 5
      And result mode is nil

    Scenario: AC-11 wrap clears retry_after in shadow mode
      Given a decision with allowed false reason "rate_limited" and retry_after 10
      And policy mode is "shadow"
      When I wrap the decision
      Then result retry_after is nil
      And original retry_after is 10

    Scenario: AC-12 wrap clears enforcement reason in shadow mode
      Given a decision with allowed false reason "budget_exceeded" and retry_after 1
      And policy mode is "shadow"
      When I wrap the decision
      Then result reason is nil
      And original reason is "budget_exceeded"

  Rule: Counter key namespacing
    Scenario: AC-9 shadow_key prefixes with shadow namespace
      Given a counter key "tb:api_rate:tenant-42"
      When I build the shadow counter key
      Then shadow key is "shadow:tb:api_rate:tenant-42"

    Scenario: AC-10 shadow_key works with cost budget keys
      Given a counter key "cb:daily_budget:org-1:1d"
      When I build the shadow counter key
      Then shadow key is "shadow:cb:daily_budget:org-1:1d"

  Rule: Consumer-facing action field
    Scenario: wrap sets decision.action to allow in addition to decision.allowed
      Given a decision with allowed false reason "rate_limited" and retry_after 5
      And policy mode is "shadow"
      When I wrap the decision
      Then result action is "allow"
      And result allowed is true

  Rule: Edge case handling
    Scenario: nil policy mode defaults to pass-through
      Given a decision with allowed false reason "rate_limited" and retry_after 5
      When I wrap the decision
      Then result allowed remains false
      And result reason remains "rate_limited"
      And result retry_after remains 5

    Scenario: nil decision returns nil
      Given a nil decision
      And policy mode is "shadow"
      When I wrap the decision
      Then wrap returns nil

    Scenario: unknown policy mode behaves like enforce
      Given a decision with allowed false reason "rate_limited" and retry_after 5
      And policy mode is "audit"
      When I wrap the decision
      Then result allowed remains false
      And result reason remains "rate_limited"
      And result retry_after remains 5

    Scenario: shadow wrap captures nil original fields
      Given a reject decision with allowed false and no reason
      And policy mode is "shadow"
      When I wrap the decision
      Then result reason is nil
      And result retry_after is nil
      And original reason is nil
      And original retry_after is nil
      And original action is "reject"

    Scenario: shadow_key with nil key returns nil and error
      Given a nil counter key
      When I build the shadow counter key
      Then shadow_key returns nil and error
