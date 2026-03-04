Feature: Cost budget golden integration scenarios
  Rule: RE-005 budget exhaustion
    Scenario: rejects after budget is consumed
      Given the nginx mock environment is reset
      And a validated daily cost budget with budget 100 fixed cost 10 and reject at 100
      And the request key is "cb:daily_limit:org-1"
      And time is set to 1708041600
      And I consume 9 checks with cost 10
      When I run one check with cost 10
      Then the check is allowed with remaining 0
      When I run one check with cost 10
      Then the check is rejected with reason "budget_exceeded"

  Rule: RE-006 staged actions
    Scenario: staged actions progress warn throttle reject
      Given the nginx mock environment is reset
      And a validated daily staged budget with warn at 80 throttle at 95 delay 200 and reject at 100
      And the request key is "cb:staged_limit:org-2"
      And time is set to 1708041600
      When I run checks with costs 79, 1, 15, 6
      Then the actions are "allow", "warn", "throttle", "reject"
      And the second result has warning true
      And the third result has delay_ms 200
      And the fourth result is rejected with budget remaining 0

  Rule: RE-014 period reset
    Scenario: exhausted budget becomes available after midnight
      Given the nginx mock environment is reset
      And a validated daily cost budget with budget 100 fixed cost 1 and reject at 100
      And the request key is "cb:daily_limit:org-3"
      And time is set to 1708041600
      And I consume 99 checks with cost 1
      When I run one check with cost 1
      Then the check is allowed with remaining 0
      When I run one check with cost 1
      Then the check is rejected with reason "budget_exceeded"
      Given time advances by 86400 seconds
      When I run one check with cost 1
      Then the check is allowed with remaining 99

  Rule: Five-minute budget window
    Scenario: exhausted five-minute budget resets on next window boundary
      Given the nginx mock environment is reset
      And a validated five-minute cost budget with budget 10 fixed cost 1 and reject at 100
      And the request key is "cb:5m_limit:org-4"
      And time is set to 1708041899
      And I consume 9 checks with cost 1
      When I run one check with cost 1
      Then the check is allowed with remaining 0
      When I run one check with cost 1
      Then the check is rejected with reason "budget_exceeded"
      Given time advances by 1 seconds
      When I run one check with cost 1
      Then the check is allowed with remaining 9
