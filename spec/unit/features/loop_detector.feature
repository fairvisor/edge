Feature: Loop detector module behavior
  Rule: Loop counting and actions
    Scenario: AC-1 below threshold returns no detection
      Given the nginx mock environment is reset
      And loop detection config has threshold 10, window 60, and action "reject"
      And fingerprint "fp-a" has been checked 8 times
      When I run one loop check for fingerprint "fp-a"
      Then the result reports no detection with count 9

    Scenario: AC-2 at threshold detects and rejects
      Given the nginx mock environment is reset
      And loop detection config has threshold 10, window 60, and action "reject"
      And fingerprint "fp-a" has been checked 9 times
      When I run one loop check for fingerprint "fp-a"
      Then the result reports detection with action "reject" and count 10
      And retry_after equals 60

    Scenario: AC-3 above threshold keeps detecting
      Given the nginx mock environment is reset
      And loop detection config has threshold 10, window 60, and action "reject"
      And fingerprint "fp-a" has been checked 14 times
      When I run one loop check for fingerprint "fp-a"
      Then the result reports detection with action "reject" and count 15

    Scenario: AC-4 throttle action applies progressive delay
      Given the nginx mock environment is reset
      And loop detection config has threshold 5, window 30, and action "throttle"
      And fingerprint "fp-a" has been checked 9 times
      When I run one loop check for fingerprint "fp-a"
      Then the result reports detection with action "throttle" and count 10
      And delay_ms equals 1000

    Scenario: AC-5 warn action marks loop and allows caller to continue
      Given the nginx mock environment is reset
      And loop detection config has threshold 5, window 30, and action "warn"
      And fingerprint "fp-a" has been checked 4 times
      When I run one loop check for fingerprint "fp-a"
      Then the result reports detection with action "warn" and count 5

    Scenario: AC-6 different fingerprints are independent
      Given the nginx mock environment is reset
      And loop detection config has threshold 5, window 30, and action "reject"
      And fingerprint "fp-a" has been checked 4 times
      And fingerprint "fp-b" has been checked 4 times
      When I run one loop check for fingerprint "fp-a"
      Then the result reports detection with action "reject" and count 5
      And fingerprint "fp-b" stored count is 4

  Rule: Fingerprint determinism
    Scenario: AC-7 method and query values influence fingerprint
      Given the nginx mock environment is reset
      When I build the fingerprint once with method POST and path /v1/chat and query model=gpt-4
      And I build the fingerprint again with method GET and path /v1/chat and query model=gpt-4
      Then the two fingerprints are different

    Scenario: AC-8 limit key values isolate fingerprint namespaces
      Given the nginx mock environment is reset
      When I build two fingerprints with different limit key values
      Then the two fingerprints are different

    Scenario: AC-9 query params are sorted for deterministic fingerprints
      Given the nginx mock environment is reset
      When I build two fingerprints with same query params in different key order
      Then the two fingerprints are equal

  Rule: Config validation and fail-open behavior
    Scenario: AC-10 validation rejects threshold less than 2
      Given loop detection config has invalid threshold 1
      When I validate the loop detection config
      Then validation fails with error "threshold_identical_requests must be >= 2"

    Scenario: AC-11 validation rejects unknown action
      Given loop detection config has unknown action "block"
      When I validate the loop detection config
      Then validation fails with error "action must be one of reject, throttle, warn"

    Scenario: validation rejects enabled config with missing window_seconds
      Given loop detection config is enabled with threshold 10 but missing window_seconds
      When I validate the loop detection config
      Then validation fails with error "when enabled is true, window_seconds is required"

    Scenario: validation rejects enabled config with missing threshold_identical_requests
      Given loop detection config is enabled with window 60 but missing threshold
      When I validate the loop detection config
      Then validation fails with error "when enabled is true, threshold_identical_requests is required"

    Scenario: AC-12 validation accepts disabled config
      Given loop detection config is disabled
      When I validate the loop detection config
      Then validation succeeds

    Scenario: check fails open when shared_dict incr errors
      Given loop detection config has threshold 5, window 30, and action "reject"
      And a dict incr error is simulated
      When I run one loop check for fingerprint "fp-a"
      Then the result reports no detection with count 0
