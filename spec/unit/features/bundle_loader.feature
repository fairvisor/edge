Feature: Policy bundle loader
  Rule: Signature, parse, and version checks
    Scenario: AC-1 valid signed bundle is loaded
      Given the bundle loader environment is reset
      And a valid signed bundle payload
      And current version is 41
      When I load the signed bundle
      Then the load succeeds
      And the compiled bundle has version 42 and non-nil hash

    Scenario: AC-2 invalid signature is rejected
      Given the bundle loader environment is reset
      And an invalid signed bundle payload
      And current version is 41
      When I load the signed bundle
      Then the load fails with error "invalid_signature"

    Scenario: AC-3 monotonic version check rejects replay
      Given the bundle loader environment is reset
      And a valid unsigned bundle payload
      And the bundle version is 41
      And current version is 42
      When I load the unsigned bundle with monotonic check
      Then the load fails with error "version_not_monotonic"

    Scenario: AC-4 higher version is accepted
      Given the bundle loader environment is reset
      And a valid unsigned bundle payload
      And the bundle version is 43
      And current version is 42
      When I load the unsigned bundle with monotonic check
      Then the load succeeds

    Scenario: AC-5 malformed json is rejected
      Given the bundle loader environment is reset
      And the bundle has malformed json
      And current version is 1
      When I load the unsigned bundle
      Then the load fails with error "json_parse_error: expected object key string at position 2"

  Rule: Apply and file loading
    Scenario: AC-6 atomic swap applies compiled bundle
      Given the bundle loader environment is reset
      And a valid unsigned bundle payload
      And current version is 1
      When I load the unsigned bundle
      And I apply the compiled bundle
      Then the active bundle is version 42

    Scenario: AC-7 bundle is loaded from file
      Given the bundle loader environment is reset
      And the bundle uses version 55 for file loading
      And current version is nil
      When I load from file
      Then the load succeeds
      And the compiled bundle has version 55 and non-nil hash

    Scenario: AC-8 health state is updated on apply
      Given the bundle loader environment is reset
      And a valid unsigned bundle payload
      And current version is nil
      When I load the unsigned bundle
      And I apply the compiled bundle
      Then health state stores version 42 and hash

  Rule: Partial validation and standalone semantics
    Scenario: AC-9 invalid policies are skipped
      Given the bundle loader environment is reset
      And the bundle contains one invalid policy out of three
      And current version is nil
      When I load the unsigned bundle
      Then the load succeeds
      And the compiled bundle has 2 valid policies
      And one validation error is logged

    Scenario: AC-10 missing signing key skips signature verification
      Given the bundle loader environment is reset
      And a valid unsigned bundle payload
      And current version is nil
      When I load the unsigned bundle
      Then the load succeeds

    Scenario: AC-11 first load with nil current version succeeds
      Given the bundle loader environment is reset
      And a valid unsigned bundle payload
      And the bundle version is 1
      And the current version is nil
      When I load the unsigned bundle
      Then the load succeeds

    Scenario: AC-13 standalone rollback allows lower version when current_version is nil
      Given the bundle loader environment is reset
      And a valid unsigned bundle payload
      And the bundle version is 10
      And the current version is nil
      When I load the unsigned bundle
      Then the load succeeds

    Scenario: AC-12 bundle hash is set for readyz display
      Given the bundle loader environment is reset
      And a valid unsigned bundle payload
      And current version is nil
      When I load the unsigned bundle
      Then the load succeeds
      And the compiled bundle has version 42 and non-nil hash

  Rule: Compiled bundle structure
    Scenario: load_from_string returns policies_by_id map keyed by policy ID
      Given the bundle loader environment is reset
      And a valid unsigned bundle payload
      And current version is nil
      When I load the unsigned bundle
      Then the load succeeds
      And the compiled bundle has policies_by_id keyed by policy ID

    Scenario: Duplicate policy IDs in bundle — last one wins in policies_by_id
      Given the bundle loader environment is reset
      And a bundle with two policies with the same ID
      And current version is nil
      When I load the unsigned bundle
      Then the load succeeds
      And policies_by_id contains exactly one entry for that ID with the last policy spec

  Rule: Fallback limit validation at load time (BUG-3)
    Scenario: load rejects policy when fallback_limit is invalid
      Given the bundle loader environment is reset
      And a bundle with policy that has invalid fallback_limit
      And current version is nil
      When I load the unsigned bundle
      Then the load succeeds
      And the compiled bundle has 0 valid policies
      And fallback_limit validation error is logged

    Scenario: load accepts policy with valid fallback_limit
      Given the bundle loader environment is reset
      And a bundle with policy that has valid fallback_limit
      And current version is nil
      When I load the unsigned bundle
      Then the load succeeds
      And the compiled bundle has 1 valid policies
      And the compiled bundle policy has fallback_limit in spec

  Rule: Additional loader API behavior
    Scenario: validate_bundle returns no top-level errors for a valid bundle
      Given the bundle loader environment is reset
      And a valid unsigned bundle payload
      When I validate the raw bundle table
      Then validation has no top-level errors

    Scenario: validate API returns success tuple for a valid bundle
      Given the bundle loader environment is reset
      And a valid unsigned bundle payload
      When I validate the raw bundle using validate API
      Then validation API reports success

    Scenario: expired bundles are rejected
      Given the bundle loader environment is reset
      And the bundle expires in the past
      When I load the unsigned bundle
      Then the load fails with error "bundle_expired"

    Scenario: hot reload timer loads and applies file content
      Given the bundle loader environment is reset
      And the hot reload file uses version 88
      And current version is nil
      When I initialize hot reload every 5 seconds
      Then hot reload initialization succeeds
      When I trigger the first hot reload callback
      Then the hot reload applies version 88

  Rule: Runtime override block validation
    Scenario: valid global shadow and kill switch override blocks are loaded
      Given the bundle loader environment is reset
      And a bundle with active global shadow and kill switch override blocks
      And current version is nil
      When I load the unsigned bundle
      Then the load succeeds
      And the compiled bundle includes runtime override blocks

    Scenario: invalid global shadow block is rejected
      Given the bundle loader environment is reset
      And a bundle with invalid global shadow block
      And current version is nil
      When I load the unsigned bundle
      Then the load fails with error "global_shadow_invalid: reason is required when enabled"

  Rule: Selector hosts validation
    Scenario: selector hosts must not be an empty array
      Given the bundle loader environment is reset
      And a bundle with selector hosts set to empty array
      And current version is nil
      When I load the unsigned bundle
      Then the load succeeds
      And the compiled bundle has 0 valid policies
      And the load logs validation error containing "selector.hosts must be a non-empty array of hostnames"

    Scenario: selector hosts rejects invalid hostname format
      Given the bundle loader environment is reset
      And a bundle with selector hosts containing invalid hostname
      And current version is nil
      When I load the unsigned bundle
      Then the load succeeds
      And the compiled bundle has 0 valid policies
      And the load logs validation error containing "selector.hosts[1] invalid hostname format"

    Scenario: selector hosts accepts uppercase hostname and normalizes
      Given the bundle loader environment is reset
      And a bundle with selector hosts using uppercase hostname
      And current version is nil
      When I load the unsigned bundle
      Then the load succeeds
      And the compiled bundle has 1 valid policies
      And the compiled policy selector host at index 1 is "api.example.com"
