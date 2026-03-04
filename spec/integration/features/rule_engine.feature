Feature: Rule engine golden integration behavior
  Rule: Golden scenarios RE-007 to RE-009
    Scenario: RE-007 shadow mode returns allow with would_reject
      Given the rule engine integration harness is reset
      And fixture RE-007 shadow policy would reject
      When I run rule engine evaluation
      Then integration decision is allow shadow would_reject true

    Scenario: RE-008 all must pass rejects on second policy
      Given the rule engine integration harness is reset
      And fixture RE-008 two policies second rejects
      When I run rule engine evaluation
      Then integration decision is reject from policy "p2"

    Scenario: RE-009 missing limit key is fail-open
      Given the rule engine integration harness is reset
      And fixture RE-009 missing limit key fail-open
      When I run rule engine evaluation
      Then integration decision is allow all rules passed
      And missing descriptor log was emitted

  Rule: Pipeline order
    Scenario: kill-switch runs before route evaluation
      Given the rule engine integration harness is reset
      And fixture kill switch takes precedence
      When I run rule engine evaluation
      Then kill switch short-circuited route evaluation

    Scenario: loop detection returns before circuit breaker and limit checks
      Given the rule engine integration harness is reset
      And fixture loop check happens before circuit and rules
      When I run rule engine evaluation
      Then loop short-circuited circuit and limiter checks

  Rule: Full chain with real modules
    Scenario: load real policy JSON then evaluate until reject after burst
      Given the full chain integration is reset with real bundle_loader and token_bucket
      And a real bundle with token_bucket burst 2 is loaded and applied
      And request context is path /v1/chat with jwt org_id org-1 and plan pro
      When I evaluate the request 3 times
      Then the first two evaluations are allow and the third is reject

    Scenario: kill switch in bundle causes matching request to reject
      Given the full chain integration is reset with real bundle_loader and token_bucket
      And a real bundle with kill_switch matching org-1 is loaded and applied
      And request context is path /v1/chat with jwt org_id org-1
      When I run rule engine evaluation
      Then integration decision is reject with reason kill_switch

    Scenario: kill switch extracts scope from request context without precomputed descriptors
      Given the full chain integration is reset with real bundle_loader and token_bucket
      And a real bundle with kill_switch matching org-1 is loaded and applied
      And request context is path /v1/chat with jwt org_id org-1 and no precomputed descriptors
      When I run rule engine evaluation
      Then integration decision is reject with reason kill_switch
