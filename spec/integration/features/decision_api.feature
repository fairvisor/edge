Feature: Decision API integration flow
  Rule: Golden decision API scenarios
    Scenario: DA-001 Allow with headers
      Given the integration nginx environment is reset
      And integration mode is "decision_service" with retry jitter "false"
      And integration decision is allow with limit "200" and remaining "150"
      When I run integration access handler
      Then integration response is allow with status untouched
      And integration header "RateLimit-Limit" equals "200"
      And integration header "RateLimit-Remaining" equals "150"
      And integration header "RateLimit-Reset" equals "1"
      And integration metric action is "allow"
      And integration cleanup restores getenv

    Scenario: DA-002 Reject with reason
      Given the integration nginx environment is reset
      And integration mode is "decision_service" with retry jitter "false"
      And integration decision is reject reason "rate_limit_exceeded" retry_after 1
      When I run integration access handler
      Then integration response is rejected with status 429
      And integration header "Retry-After" is between 1 and 2
      And integration metric action is "reject"
      And integration retry after bucket metric is "le_5"
      And integration cleanup restores getenv

    Scenario: DA-003 Kill-switch rejection
      Given the integration nginx environment is reset
      And integration mode is "decision_service" with retry jitter "false"
      And integration decision is reject reason "kill_switch" retry_after 3600
      When I run integration access handler
      Then integration response is rejected with status 429
      And integration header "Retry-After" is between 3600 and 5400
      And integration cleanup restores getenv

    Scenario: DA-004 Shadow mode headers
      Given the integration nginx environment is reset
      And integration mode is "decision_service" with retry jitter "false"
      And integration decision is shadow allow with would reject metadata
      When I run integration access handler
      Then integration response is allow with status untouched
      And integration logs contain shadow mode
      And integration header "X-Fairvisor-Would-Reject" equals "true"
      And integration cleanup restores getenv
