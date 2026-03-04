Feature: Response-based cost extraction
  Rule: Response parsing guardrails and extraction
    Scenario: AC-1 extracts usage from standard response
      Given the nginx mock environment is reset
      And a valid response cost config
      And response body has usage prompt 1500 completion 850 total 2350
      When I extract usage from response
      Then response usage total is 2350 prompt is 1500 completion is 850

    Scenario: AC-2 body too large triggers fallback
      Given the nginx mock environment is reset
      And a valid response cost config
      And response body is larger than max_parseable_body_bytes
      When I extract usage from response
      Then extraction fails with reason "body_too_large" and fallback true

    Scenario: AC-3 malformed JSON triggers fallback
      Given the nginx mock environment is reset
      And a valid response cost config
      And response body is "not json"
      When I extract usage from response
      Then extraction fails with reason "json_parse_error" and fallback true

    Scenario: AC-4 missing usage triggers fallback
      Given the nginx mock environment is reset
      And a valid response cost config
      And response body has no usage
      When I extract usage from response
      Then extraction fails with reason "usage_not_found" and fallback true

    Scenario: AC-6 custom json path resolves nested usage
      Given the nginx mock environment is reset
      And a valid response cost config
      And custom json_path is data usage
      When I extract usage from response
      Then response usage total is 100

    Scenario: supports json_path extracting total only value
      Given the nginx mock environment is reset
      And a valid response cost config
      And custom json_path is data usage total only
      When I extract usage from response
      Then response usage total is 120

    Scenario: AC-7 computes total when total_tokens missing
      Given the nginx mock environment is reset
      And a valid response cost config
      And response body has usage prompt 100 completion 50 without total
      When I extract usage from response
      Then response usage total is 150 prompt is 100 completion is 50

    Scenario: parse timeout triggers fallback
      Given the nginx mock environment is reset
      And a valid response cost config
      And ngx now reports slow parse exceeding max_parse_time_ms
      When I extract usage from response
      Then extraction fails with reason "parse_timeout" and fallback true

  Rule: SSE and path helper behavior
    Scenario: AC-5 extracts usage from SSE final event
      Given the nginx mock environment is reset
      And SSE final event data has usage prompt 300 completion 200 total 500
      When I extract usage from SSE final event
      Then SSE usage total is 500 prompt is 300 completion is 200

    Scenario: SSE extraction returns nil when usage absent
      Given the nginx mock environment is reset
      And SSE final event data has no usage
      When I extract usage from SSE final event
      Then SSE usage is nil

    Scenario: extract_json_path walks dot notation
      Given the nginx mock environment is reset
      When I extract json path "$.usage.total_tokens" from object with usage total 42
      Then json path value is 42

    Scenario: extract_json_path returns nil for nil object
      Given the nginx mock environment is reset
      When I extract json path "$.usage" from nil object
      Then json path value is nil

    Scenario: extract_json_path returns nil for empty path
      Given the nginx mock environment is reset
      When I extract json path "" from object with usage total 42
      Then json path value is nil

  Rule: Config validation and reconciliation
    Scenario: validate config applies defaults
      Given the nginx mock environment is reset
      And config has defaults only
      When I validate cost extractor config
      Then validation succeeds
      And defaults are applied to response cost config

    Scenario: validate config rejects non-table config
      Given the nginx mock environment is reset
      And config is not a table
      When I validate cost extractor config
      Then validation fails with error "config must be a table"

    Scenario: validate config rejects empty paths
      Given the nginx mock environment is reset
      And config json_paths is empty
      When I validate cost extractor config
      Then validation fails with error "json_paths must be a non-empty array"

    Scenario: validate config rejects json_paths with empty string entry
      Given the nginx mock environment is reset
      And config json_paths contains empty string
      When I validate cost extractor config
      Then validation fails with error "json_paths entries must be non-empty strings"

    Scenario: AC-8 reconcile computes refund and ratio
      Given the nginx mock environment is reset
      And a valid response cost config
      And llm_limiter reconcile stub is installed
      And reservation estimated total is 3000 and key is tb:llm:user-1
      And extraction actual total is 2350
      And reconcile now is 1002.25
      When I reconcile extraction result
      Then reconcile refunded is 650 and ratio is 1.277
      And llm_limiter reconcile is called once with estimated 3000 and actual 2350

    Scenario: missing extraction result uses fallback reconciliation
      Given the nginx mock environment is reset
      And a valid response cost config
      And reservation estimated total is 3000 and key is tb:llm:user-1
      And reconcile now is 1002.25
      When I reconcile with missing extraction result
      Then fallback reconciliation refunded is 0 and cost_source_fallback true

    Scenario: reconcile fails when reservation is not a table
      Given the nginx mock environment is reset
      And extraction actual total is 100
      And reservation is not a table
      And reconcile now is 1000
      When I reconcile extraction result
      Then reconcile fails with error "reservation must be a table"
