Feature: LLM limiter module behavior
  Rule: Config validation and defaults
    Scenario: accepts valid config and fills defaults
      Given a valid llm limiter config with tokens_per_minute 100000
      And I validate the llm limiter config
      Then validation succeeds
      And burst_tokens defaults to tokens_per_minute

    Scenario: rejects burst smaller than tokens_per_minute
      Given a valid llm limiter config with tokens_per_minute 1000
      And the config has burst_tokens 999
      And I validate the llm limiter config
      Then validation fails with error "burst_tokens must be >= tokens_per_minute"

  Rule: Pre-flight and budget enforcement
    Scenario: AC-1 TPM allows request within budget
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 6000
      And the llm limiter config is validated
      And the request body has 4000 prompt characters in messages
      And the request max_tokens is 4000
      When I run llm check at now 1700000000
      Then check is allowed
      And remaining_tpm is 1000

    Scenario: AC-2 TPM rejects when exhausted
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 10000
      And the llm limiter config is validated
      And the request body is empty
      And the request max_tokens is 10000
      When I run llm check at now 1700000000
      Then check is allowed
      When I run llm check again at now 1700000000
      Then second check is rejected with reason "tpm_exceeded"

    Scenario: AC-3 pre-flight rejects oversized prompt
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 10000
      And the config has max_prompt_tokens 2048
      And the llm limiter config is validated
      And the request body has 12000 prompt characters in messages
      And the request max_tokens is 1
      When I run llm check at now 1700000000
      Then check is rejected with reason "prompt_tokens_exceeded"

    Scenario: AC-4 pre-flight rejects oversized total
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 10000
      And the config has max_tokens_per_request 4096
      And the llm limiter config is validated
      And the request body has 4000 prompt characters in messages
      And the request max_tokens is 4000
      When I run llm check at now 1700000000
      Then check is rejected with reason "max_tokens_per_request_exceeded"
      And estimated_total is 5000

    Scenario: AC-5 TPD daily limit rejects over budget
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 100000
      And the config has tokens_per_day 1000000
      And the llm limiter config is validated
      And TPD has already consumed 999000 tokens at now 1700000000
      And the request body is empty
      And the request max_tokens is 2000
      When I run llm check at now 1700000000
      Then check is rejected with reason "tpd_exceeded"
      And remaining_tokens is 1000
      And retry_after is at least 1

    Scenario: TPM allows but TPD rejects — TPM is refunded
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 10000
      And the config has tokens_per_day 100000
      And the llm limiter config is validated
      And TPD has already consumed 99900 tokens at now 1700000000
      And the request body is empty
      And the request max_tokens is 500
      When I run llm check at now 1700000000
      Then check is rejected with reason "tpd_exceeded"
      And TPM bucket was refunded to full capacity

    Scenario: AC-6 TPD resets at midnight UTC via date key rollover
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 100000
      And the config has tokens_per_day 1000
      And the llm limiter config is validated
      And TPD has already consumed 1000 tokens at now 1700000000
      And the request body is empty
      And the request max_tokens is 1
      When I run llm check at now 1700000000
      Then check is rejected with reason "tpd_exceeded"
      When I run llm check again at now 1700086401
      Then second check is allowed

    Scenario: TPD storage errors fail open and keep request allowed
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 10000
      And the config has tokens_per_day 100000
      And the llm limiter config is validated
      And the request body is empty
      And the request max_tokens is 500
      And TPD shared dict incr returns an error
      When I run llm check at now 1700000000
      Then check is allowed
      And remaining_tpd is not set

    Scenario: AC-7 pessimistic reservation returns reserved tokens
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 10000
      And the llm limiter config is validated
      And the request body has 4000 prompt characters in messages
      And the request max_tokens is 4000
      When I run llm check at now 1700000000
      Then check is allowed
      And reserved equals estimated_total 5000
      And prompt_tokens is 1000

    Scenario: AC-12 TPD rollback on TPM success plus TPD failure
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 600
      And the config has burst_tokens 600
      And the config has tokens_per_day 1000
      And the llm limiter config is validated
      And TPD has already consumed 500 tokens at now 1700000000
      And the request body is empty
      And the request max_tokens is 600
      When I run llm check at now 1700000000
      Then check is rejected with reason "tpd_exceeded"
      When I run llm check again at now 1700000000
      Then second check is rejected with reason "tpd_exceeded"

    Scenario: BUG-4 TPD budget uses atomic incr so key reflects consumed tokens
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 100000
      And the config has tokens_per_day 50000
      And the llm limiter config is validated
      And the request body is empty
      And the request max_tokens is 300
      When I run llm check at now 1700000000
      Then check is allowed
      And TPD key value equals 300 at now 1700000000

  Rule: Estimation, reconciliation, and error response
    Scenario: AC-8 reconciliation refunds unused tokens
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 10000
      And the config has tokens_per_day 50000
      And the llm limiter config is validated
      And the request body is empty
      And the request max_tokens is 5000
      When I run llm check at now 1700000000
      Then check is allowed
      When I reconcile estimated 5000 actual 3000 at now 1700000000
      Then reconcile refunded equals 2000
      And a follow-up check with estimated_total 5000 is allowed at now 1700000000

    Scenario: AC-9 simple_word estimation parses message content only
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 10000
      And the config uses estimator "simple_word"
      And the llm limiter config is validated
      And the request body has 400 prompt characters and extra metadata 600
      When I estimate prompt tokens
      Then prompt estimate equals 100

    Scenario: AC-10 header_hint estimator uses header value
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 10000
      And the config uses estimator "header_hint"
      And the llm limiter config is validated
      And the request body has 400 prompt characters in messages
      And the request has header X-Token-Estimate 1500
      When I estimate prompt tokens
      Then prompt estimate equals 1500

    Scenario: AC-10b header_hint is case-insensitive for X-Token-Estimate
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 10000
      And the config uses estimator "header_hint"
      And the llm limiter config is validated
      And the request body has 400 prompt characters in messages
      And the request has header "x-token-estimate" with value 1500
      When I estimate prompt tokens
      Then prompt estimate equals 1500

    Scenario: AC-11 OpenAI-compatible error response
      Given the nginx mock environment is reset
      And a valid llm limiter config with tokens_per_minute 10000
      And the llm limiter config is validated
      When I build error response for reason "tpm_exceeded"
      Then error response has OpenAI rate limit shape
