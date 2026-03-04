Feature: Kill-switch enforcement
  Rule: Scope and route matching
    Scenario: AC-1 Kill-switch matches by scope_key and scope_value
      Given the nginx mock environment is reset
      And kill switches include scope "jwt:org_id" value "org_xyz"
      And descriptors include "jwt:org_id" as "org_xyz"
      And the route is "/v1/inference"
      And the current time is now
      When I check kill switches
      Then result is matched with kill_switch reason
      And result includes scope "jwt:org_id" and value "org_xyz"

    Scenario: AC-2 Kill-switch does not match different scope_value
      Given the nginx mock environment is reset
      And kill switches include scope "jwt:org_id" value "org_xyz"
      And descriptors include "jwt:org_id" as "org_abc"
      And the route is "/v1/inference"
      And the current time is now
      When I check kill switches
      Then result is not matched

    Scenario: AC-3 Route-scoped kill-switch only matches on that route
      Given the nginx mock environment is reset
      And kill switches include scope "jwt:org_id" value "org_xyz" on route "/v1/inference"
      And descriptors include "jwt:org_id" as "org_xyz"
      And the route is "/v1/data"
      And the current time is now
      When I check kill switches
      Then result is not matched

    Scenario: AC-4 Route-scoped kill-switch matches on correct route
      Given the nginx mock environment is reset
      And kill switches include scope "jwt:org_id" value "org_xyz" on route "/v1/inference"
      And descriptors include "jwt:org_id" as "org_xyz"
      And the route is "/v1/inference"
      And the current time is now
      When I check kill switches
      Then result is matched with kill_switch reason
      And result route is "/v1/inference"

    Scenario: AC-7 No route field means match on all routes
      Given the nginx mock environment is reset
      And kill switches include scope "jwt:org_id" value "org_xyz"
      And descriptors include "jwt:org_id" as "org_xyz"
      And the route is "/any/route"
      And the current time is now
      When I check kill switches
      Then result is matched with kill_switch reason

    Scenario: AC-8 Multiple kill-switches first match wins
      Given the nginx mock environment is reset
      And two kill switches include "org_abc" then "org_xyz" for scope "jwt:org_id"
      And descriptors include "jwt:org_id" as "org_xyz"
      And the route is "/v1/inference"
      And the current time is now
      When I check kill switches
      Then result is matched with kill_switch reason
      And result includes scope "jwt:org_id" and value "org_xyz"
      And result reason text is "second"

    Scenario: AC-9 Missing descriptor key means no match
      Given the nginx mock environment is reset
      And kill switches include scope "jwt:org_id" value "org_xyz"
      And descriptors include "header:X-API-Key" as "key-123"
      And the route is "/v1/inference"
      And the current time is now
      When I check kill switches
      Then result is not matched

    Scenario: AC-10 Empty kill_switches list returns no match
      Given the nginx mock environment is reset
      And kill switches are an empty list
      And descriptors are nil
      And the route is "/v1/inference"
      And the current time is now
      When I check kill switches
      Then result is not matched

    Scenario: Nil kill_switches returns no match
      Given the nginx mock environment is reset
      And kill switches are nil
      And descriptors include "jwt:org_id" as "org_xyz"
      And the route is "/v1/inference"
      And the current time is now
      When I check kill switches
      Then result is not matched

  Rule: Expiry behavior
    Scenario: AC-5 Expired kill-switch is ignored
      Given the nginx mock environment is reset
      And kill switches include scope "jwt:org_id" value "org_xyz" expiring at "2026-02-03T14:00:00Z"
      And descriptors include "jwt:org_id" as "org_xyz"
      And the route is "/v1/inference"
      And the current time is ISO "2026-02-03T14:00:01Z"
      When I validate kill switches
      Then validation succeeds
      And the kill switch has cached expiry epoch
      When I check kill switches
      Then result is not matched

    Scenario: AC-6 Non-expired kill-switch matches
      Given the nginx mock environment is reset
      And kill switches include scope "jwt:org_id" value "org_xyz" expiring at "2026-02-03T14:00:00Z"
      And descriptors include "jwt:org_id" as "org_xyz"
      And the route is "/v1/inference"
      And the current time is ISO "2026-02-03T13:59:59Z"
      When I validate kill switches
      Then validation succeeds
      And the kill switch has cached expiry epoch
      When I check kill switches
      Then result is matched with kill_switch reason

  Rule: Validation
    Scenario: AC-11 Validation rejects invalid scope_key format
      Given kill switches include scope "invalid_format" value "org_xyz"
      When I validate kill switches
      Then validation fails with error containing "scope_key"

    Scenario: AC-12 Validation rejects missing scope_value
      Given kill switches include scope "jwt:org_id" with missing scope value
      When I validate kill switches
      Then validation fails with error containing "scope_value"

    Scenario: Validation accepts nil kill-switch list
      Given kill switches are nil
      When I validate kill switches
      Then validation succeeds

    Scenario: Validation rejects invalid route
      Given kill switches include scope "jwt:org_id" value "org_xyz" on route "v1/inference"
      When I validate kill switches
      Then validation fails with error containing "route"

    Scenario: Validation rejects malformed expiry timestamp
      Given kill switches include scope "jwt:org_id" value "org_xyz" expiring at "2026-02-03 14:00:00"
      When I validate kill switches
      Then validation fails with error containing "expires_at"

  Rule: ISO8601 utility parser
    Scenario: Parse valid UTC timestamp
      When I parse timestamp "2026-02-03T14:00:00Z"
      Then parsed epoch is present

    Scenario: Reject non-UTC offset timestamp
      When I parse timestamp "2026-02-03T14:00:00+01:00"
      Then parsed epoch is nil

    Scenario: Reject impossible calendar date
      When I parse timestamp "2026-02-30T14:00:00Z"
      Then parsed epoch is nil
