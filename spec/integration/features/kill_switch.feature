Feature: Kill-switch integration behavior
  Rule: Mixed entry evaluation
    Scenario: Expired route-scoped entry is skipped and later route entry matches
      Given the nginx mock environment is reset
      And a mixed kill-switch bundle is configured
      And descriptors contain org "org_xyz" and api key "safe-key"
      And the route is "/v1/inference"
      And the request time is "2026-02-03T11:00:00Z"
      When I validate the kill-switch bundle
      Then bundle validation succeeds
      When I run kill-switch evaluation
      Then the request is rejected by kill-switch
      And the matched scope key is "jwt:org_id"
      And the matched scope value is "org_xyz"
      And the matched kill-switch reason is "route block"

    Scenario: Route mismatch skips route-scoped entry and global header entry matches
      Given the nginx mock environment is reset
      And a mixed kill-switch bundle is configured
      And descriptors contain org "org_xyz" and api key "key-123"
      And the route is "/v1/data"
      And the request time is "2026-02-03T11:00:00Z"
      When I validate the kill-switch bundle
      Then bundle validation succeeds
      When I run kill-switch evaluation
      Then the request is rejected by kill-switch
      And the matched scope key is "header:X_API_Key"
      And the matched scope value is "key-123"
      And the matched kill-switch reason is "global key block"

    Scenario: No matching scope values results in allow path
      Given the nginx mock environment is reset
      And a mixed kill-switch bundle is configured
      And descriptors contain org "org_safe" only
      And the route is "/v1/data"
      And the request time is "2026-02-03T11:00:00Z"
      When I validate the kill-switch bundle
      Then bundle validation succeeds
      When I run kill-switch evaluation
      Then the request is not rejected by kill-switch
