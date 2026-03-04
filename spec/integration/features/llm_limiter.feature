Feature: LLM limiter integration contract tests
  Rule: Golden tests TK-001 through TK-003
    Scenario: TK-001 basic TPM enforcement
      Given the nginx mock environment is reset
      And an llm limiter config with tokens_per_minute 10000, burst_tokens 10000, and default_max_completion 1000
      And request context has empty body and max_tokens 10000
      When I run check at now 1700000000
      Then the check is allowed with remaining_tpm 0
      And the check reserved 10000 tokens
      When I run a second check at now 1700000000
      Then the second check is rejected with reason "tpm_exceeded"

    Scenario: TK-002 pre-flight rejection
      Given the nginx mock environment is reset
      And an llm limiter config with tokens_per_minute 10000, max_prompt_tokens 2048, and default_max_completion 1000
      And request context has 12000 prompt characters and max_tokens 1000
      When I run check at now 1700000000
      Then the check is rejected with reason "prompt_tokens_exceeded"

    Scenario: TK-003 reconciliation refund
      Given the nginx mock environment is reset
      And an llm limiter config with tokens_per_minute 100000, burst_tokens 100000, and default_max_completion 1000
      And request context has empty body and max_tokens 5000
      When I run check at now 1700000000
      Then the check is allowed with remaining_tpm 95000
      And the check reserved 5000 tokens
      When I reconcile estimated 5000 with actual 3000 at now 1700000000
      Then the reconcile refunded 2000 tokens
      When I run a second check at now 1700000000
      Then the second check is allowed
