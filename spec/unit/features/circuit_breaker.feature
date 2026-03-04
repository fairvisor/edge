Feature: Budget circuit breaker behavior
  Rule: Validation and state transitions
    Scenario: AC-1 breaker stays closed when spend rate is below threshold
      Given the nginx mock environment is reset
      And circuit breaker threshold is 1000 and auto_reset_after_minutes is 5
      And 500 cost units accumulated in the current window
      When I check with cost 100
      Then the breaker result is tripped false with state "closed"
      And the spend_rate is 600

    Scenario: AC-2 breaker trips when spend rate reaches threshold
      Given the nginx mock environment is reset
      And circuit breaker threshold is 1000 and auto_reset_after_minutes is 5
      And 900 cost units accumulated in the current window
      When I check with cost 100
      Then the breaker result is tripped true with state "open"
      And the reason is "circuit_breaker_open"
      And the spend_rate is 1000

    Scenario: AC-3 open breaker rejects all subsequent requests
      Given the nginx mock environment is reset
      And the breaker is open for limit key "org-1"
      When I check with cost 1
      Then the breaker result is tripped true with state "open"
      And the reason is "circuit_breaker_open"
      And the spend_rate is nil

    Scenario: AC-4 auto-reset closes breaker after cooldown
      Given the nginx mock environment is reset
      And circuit breaker threshold is 1000 and auto_reset_after_minutes is 5
      And the breaker opened 5 minutes ago
      When I check with cost 1
      Then the breaker result is tripped false with state "closed"

    Scenario: AC-5 auto-reset disabled keeps breaker open
      Given the nginx mock environment is reset
      And circuit breaker threshold is 1000 and auto_reset_after_minutes is 0
      And the breaker opened 60 minutes ago
      When I check with cost 1
      Then the breaker result is tripped true with state "open"

    Scenario: AC-6 manual reset closes breaker and clears tracking keys
      Given the nginx mock environment is reset
      And the limit key is "org-1"
      And the breaker is open for limit key "org-1"
      And 50 cost units accumulated in the current window
      When I reset the breaker for limit key "org-1"
      Then the state key for limit key "org-1" is cleared
      And current and previous rate keys for limit key "org-1" are cleared
      When I check with cost 1
      Then the breaker result is tripped false with state "closed"

    Scenario: AC-7 different limit keys are independent
      Given the nginx mock environment is reset
      And the breaker is open for limit key "org-1"
      Then org-2 is not affected and remains closed

    Scenario: AC-8 alert flag is passed through when breaker trips
      Given the nginx mock environment is reset
      And circuit breaker threshold is 100 and auto_reset_after_minutes is 5
      And circuit breaker alert is true
      And 90 cost units accumulated in the current window
      When I check with cost 10
      Then the breaker result is tripped true with state "open"
      And the alert field is true

    Scenario: AC-9 spend_rate reflects accumulated cost
      Given the nginx mock environment is reset
      And circuit breaker threshold is 1000 and auto_reset_after_minutes is 5
      When I run three checks with costs 100, 200, and 300
      Then the breaker result is tripped false with state "closed"
      And the spend_rate is 600

    Scenario: AC-10 validation rejects zero threshold
      Given the nginx mock environment is reset
      And a config with threshold 0 and auto_reset_after_minutes 5
      When I validate the circuit breaker config
      Then validation fails with error "circuit_breaker.spend_rate_threshold_per_minute must be a positive number"

    Scenario: AC-11 validation rejects negative auto-reset
      Given the nginx mock environment is reset
      And a config with threshold 100 and auto_reset_after_minutes -1
      When I validate the circuit breaker config
      Then validation fails with error "circuit_breaker.auto_reset_after_minutes must be a non-negative number"

    Scenario: AC-12 disabled config passes validation
      Given the nginx mock environment is reset
      And a disabled circuit breaker config
      When I validate the circuit breaker config
      Then validation succeeds

    Scenario: AC-13 disabled breaker returns closed without touching dict
      Given the nginx mock environment is reset
      And circuit breaker threshold is 1000 and auto_reset_after_minutes is 5
      And circuit breaker is disabled
      When I check with cost 10000
      Then the breaker result is tripped false with state "closed"
      And the spend_rate is nil

  Rule: Fail-open on dict errors
    Scenario: check when dict set for state fails returns closed
      Given the nginx mock environment is reset
      And circuit breaker threshold is 100 and auto_reset_after_minutes is 5
      And a dict that fails set for state key is used
      And 90 cost units accumulated in the current window
      When I check with cost 10 using the set-failing dict
      Then the breaker result is tripped false with state "closed"
