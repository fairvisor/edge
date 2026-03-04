Feature: Rule evaluation engine orchestration
  Rule: Acceptance criteria from feature 006
    Scenario: AC-1 all must pass across matching policies
      Given the rule engine test environment is reset
      And fixture AC-1 all must pass with second policy rejection
      When I evaluate the request
      Then decision action is "reject"
      And decision reason is "rate_limited"
      And decision policy_id is "p2"
      And decision rule_name is "p2_rule"

    Scenario: AC-2 claim matching uses AND semantics
      Given the rule engine test environment is reset
      And fixture AC-2 claim mismatch skips rule
      When I evaluate the request
      Then decision action is "allow"
      And decision reason is "all_rules_passed"
      And token bucket check was not called

    Scenario: AC-3 fallback limit is used when no rules match
      Given the rule engine test environment is reset
      And fixture AC-3 fallback limit applies
      When I evaluate the request
      Then decision action is "allow"
      And token bucket check was called for "fallback_rule"

    Scenario: AC-4 no matching rules and no fallback means implicit allow
      Given the rule engine test environment is reset
      And fixture AC-4 no matching rules and no fallback
      When I evaluate the request
      Then decision action is "allow"
      And decision reason is "all_rules_passed"
      And token bucket check was not called

    Scenario: AC-5 kill-switch executes before all other checks
      Given the rule engine test environment is reset
      And fixture AC-5 kill switch matches
      When I evaluate the request
      Then decision action is "reject"
      And decision reason is "kill_switch"
      And route matching did not run

    Scenario: AC-6 pipeline order is kill-switch then loop before circuit and rules
      Given the rule engine test environment is reset
      And fixture AC-6 loop detection triggers before circuit and rules
      When I evaluate the request
      Then decision action is "reject"
      And kill switch ran before route matching
      And loop check ran before circuit and limiter checks

    Scenario: loop detection throttle action returns throttle decision with delay
      Given the rule engine test environment is reset
      And fixture loop detection throttles instead of rejecting
      When I evaluate the request
      Then decision action is "throttle"
      And loop throttle decision includes delay_ms 900

    Scenario: AC-7 shadow mode returns allow when rule would reject
      Given the rule engine test environment is reset
      And fixture AC-7 shadow mode wraps reject as allow
      When I evaluate the request
      Then decision is shadow allow with would_reject true

    Scenario: AC-8 missing descriptor is fail-open with log and metric
      Given the rule engine test environment is reset
      And fixture AC-8 missing descriptor is fail-open
      When I evaluate the request
      Then decision action is "allow"
      And decision reason is "all_rules_passed"
      And missing descriptor was logged and metered

    Scenario: AC-9 decision includes rate limit headers on allow
      Given the rule engine test environment is reset
      And fixture AC-9 allow includes rate headers
      When I evaluate the request
      Then decision action is "allow"
      And allow decision includes RateLimit headers

    Scenario: AC-10 reject includes fairvisor reason and retry-after
      Given the rule engine test environment is reset
      And fixture AC-10 reject includes reason and retry headers
      When I evaluate the request
      Then decision action is "reject"
      And reject decision includes fairvisor reason and retry headers

  Rule: Defensive bundle state
    Scenario: evaluate with bundle missing policies_by_id — logs warning and returns allow
      Given the rule engine test environment is reset
      And fixture bundle missing policies_by_id with matching route
      When I evaluate the request
      Then decision action is "allow"
      And policies_by_id missing was logged and metered

    Scenario: evaluate when route_index returns policy_id not in policies_by_id
      Given the rule engine test environment is reset
      And fixture route returns policy_id not in policies_by_id
      When I evaluate the request
      Then decision action is "allow"
      And policy not found in policies_by_id was logged

    Scenario: duplicate route matches are evaluated once per policy
      Given the rule engine test environment is reset
      And fixture duplicate route matches evaluate each policy once
      When I evaluate the request
      Then decision action is "allow"
      And token bucket check was called 1 time for "dedupe_rule"
      And policy evaluation metric count for "p1" is 1

    Scenario: route matching receives host from request context
      Given the rule engine test environment is reset
      And fixture route matching receives normalized host context
      When I evaluate the request
      Then decision action is "allow"
      And decision reason is "no_matching_policy"
      And route matching received host "api.example.com" method "GET" and path "/v1/chat"

  Rule: Runtime override modes
    Scenario: global shadow override forces allow while preserving observability
      Given the rule engine test environment is reset
      And fixture global shadow override forces allow with headers
      When I evaluate the request
      Then decision action is "allow"
      And decision reason is "rate_limited"
      And decision does not expose override headers
      And global shadow metrics are emitted

    Scenario: kill switch override disables kill switch enforcement
      Given the rule engine test environment is reset
      And fixture kill switch override skips kill switch
      When I evaluate the request
      Then decision action is "allow"
      And kill switch check was skipped
      And decision does not expose override headers
