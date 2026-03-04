Feature: Circuit breaker integration flows
  Rule: Golden behavior RE-012 and RE-013
    Scenario: RE-012 circuit breaker triggers and stays open
      Given the nginx mock environment is reset
      And I apply 10 requests with cost 9
      Then the result is tripped false with state "closed"
      And the spend_rate is 90
      When I run one request with cost 11
      Then the result is tripped true with state "open"
      And the spend_rate is 101
      And the reason is "circuit_breaker_open"
      And the alert is true
      When I run one request with cost 1
      Then the result is tripped true with state "open"
      And the reason is "circuit_breaker_open"

    Scenario: RE-013 below threshold stays allowed
      Given the nginx mock environment is reset
      And I apply 9 requests with cost 10
      Then the result is tripped false with state "closed"
      And the spend_rate is 90
      When I run one request with cost 1
      Then the result is tripped false with state "closed"
      And the spend_rate is 91

  Rule: Auto-reset interaction
    Scenario: open breaker auto-resets and resumes normal evaluation
      Given the nginx mock environment is reset
      And a threshold of 100 and auto_reset_after_minutes 5
      And the breaker is opened now
      And time advances by 5 minutes
      When I run one request with cost 1
      Then the result is tripped false with state "closed"
      And the spend_rate is 1
