Feature: Token bucket rate limiting
  Rule: Basic enforcement and refill behavior
    Scenario: RE-001 basic rate limit enforcement
      Given the nginx mock environment is reset
      And a token bucket with 10 tokens per second and burst 10
      And the request key is "tb:test_rule:user-1"
      When I run 10 requests with default cost
      Then all requests are allowed with remaining tokens: 9, 8, 7, 6, 5, 4, 3, 2, 1, 0
      And the next request is rejected with retry_after 1

    Scenario: RE-002 refill after time passes
      Given the nginx mock environment is reset
      And a token bucket with 10 tokens per second and burst 10
      And the request key is "tb:test_rule:user-1"
      And I consume 10 requests with default cost
      When I run 1 requests with default cost
      Then the request is rejected
      Given time advances by 0.5 seconds
      When I run 1 requests with default cost
      Then the request is allowed with remaining tokens 4

  Rule: Weighted cost and key isolation
    Scenario: RE-003 weighted cost
      Given the nginx mock environment is reset
      And a token bucket with 10 tokens per second, burst 20, and fixed cost 5
      And the request key is "tb:test_rule:user-2"
      When I run 4 requests with cost 5
      Then all requests are allowed with remaining tokens: 15, 10, 5, 0
      And the next request is rejected with retry_after 1

    Scenario: RE-004 multi-key isolation
      Given the nginx mock environment is reset
      And a token bucket with 5 tokens per second and burst 5
      When I run one request with key "tb:rule:user-A" and default cost
      Then the request is allowed with remaining tokens 4
      When I run one request with key "tb:rule:user-A" and default cost
      Then the request is allowed with remaining tokens 3
      When I run one request with key "tb:rule:user-B" and default cost
      Then the request is allowed with remaining tokens 4
      Given the request key is "tb:rule:user-A"
      And I consume 3 requests with default cost
      Then the next request is rejected with retry_after 1
      When I run one request with key "tb:rule:user-B" and default cost
      Then the request is allowed with remaining tokens 3
