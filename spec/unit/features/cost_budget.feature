Feature: Cost budget limiter module behavior
  Rule: Config validation and normalization
    Scenario: validates a well-formed cost budget config
      Given a default cost budget config
      When I validate the config
      Then validation succeeds
      And cost key cache is kind "fixed" and name ""

    Scenario: rejects non-table config
      Given a config with non-table value
      When I validate the config
      Then validation fails with error "config must be a table"

    Scenario: rejects non-cost_based algorithm
      Given a config with algorithm "token_bucket"
      When I validate the config
      Then validation fails with error "algorithm must be cost_based"

    Scenario: rejects unknown period
      Given a config with period "30m"
      When I validate the config
      Then validation fails with error "period must be one of 5m, 1h, 1d, 7d"

    Scenario: rejects invalid cost_key format
      Given a config with invalid cost_key "cookie:token_count"
      When I validate the config
      Then validation fails with error "cost_key must be fixed, header:<name>, or query:<name>"

    Scenario: rejects non-positive fixed_cost when cost_key is fixed
      Given a config with cost_key fixed and fixed_cost 0
      When I validate the config
      Then validation fails with error "fixed_cost must be a positive number"

    Scenario: rejects empty staged_actions
      Given a config with empty staged_actions
      When I validate the config
      Then validation fails with error "staged_actions must be a non-empty table"

    Scenario: rejects throttle staged action without delay
      Given a config with throttle action missing delay_ms
      When I validate the config
      Then validation fails with error "delay_ms must be a positive number for throttle action"

    Scenario: sorts staged actions by threshold during validation
      Given a config with staged actions thresholds 100, 80, 95
      When I validate the config
      Then validation succeeds
      And staged actions are sorted ascending as 80, 95, 100

    Scenario: rejects duplicate staged action thresholds
      Given a config with duplicate staged action thresholds 80 and 80
      When I validate the config
      Then validation fails with error "staged_actions thresholds must be strictly ascending"

    Scenario: rejects configs missing reject at 100
      Given a config missing reject at 100 percent
      When I validate the config
      Then validation fails with error "staged_actions must include reject at 100%"

  Rule: Key generation and cost resolution
    Scenario: builds prefixed cost budget key
      When I build key from rule "daily_budget" and limit key "org-1"
      Then the built key is "cb:daily_budget:org-1"

    Scenario: resolves fixed cost
      Given a resolve config with cost_key "fixed" fixed_cost 10 default_cost 1
      And an empty request context
      When I resolve request cost
      Then the resolved cost is 10

    Scenario: resolves header cost value
      Given a resolve config with cost_key "header:X-Token-Count" fixed_cost 1 default_cost 1
      And an empty request context
      And request headers contain "X-Token-Count" as "50"
      When I resolve request cost
      Then the resolved cost is 50

    Scenario: resolves query cost value
      Given a resolve config with cost_key "query:token_count" fixed_cost 1 default_cost 1
      And an empty request context
      And request query contains "token_count" as "25"
      When I resolve request cost
      Then the resolved cost is 25

    Scenario: falls back to default_cost when header missing
      Given a resolve config with cost_key "header:X-Token-Count" fixed_cost 1 default_cost 5
      And an empty request context
      When I resolve request cost
      Then the resolved cost is 5

    Scenario: falls back to default_cost when query value is non-positive
      Given a resolve config with cost_key "query:token_count" fixed_cost 1 default_cost 7
      And an empty request context
      And request query contains "token_count" as "0"
      When I resolve request cost
      Then the resolved cost is 7

    Scenario: uses parsed cost key fields after validation
      Given a validated resolve config with cost_key "header:X-Token-Count" fixed_cost 1 default_cost 1
      And an empty request context
      And request headers contain "X-Token-Count" as "11"
      When I resolve request cost
      Then the resolved cost is 11

  Rule: Period boundary computation
    Scenario: computes hourly period boundary
      When I compute period start for period "1h" at now 1770129000
      Then the period start is 1770127200

    Scenario: computes five-minute period boundary
      When I compute period start for period "5m" at now 1770129299
      Then the period start is 1770129000

    Scenario: computes daily period boundary
      When I compute period start for period "1d" at now 1770129000
      Then the period start is 1770076800

    Scenario: computes weekly period boundary aligned to Monday UTC
      When I compute period start for period "7d" at now 1770129000
      Then the period start is 1769904000

    Scenario: rejects unknown period in period start computation
      When I compute period start for period "30m" at now 1770129000
      Then period start computation fails with "unknown period"

  Rule: Runtime budget checks and staged actions
    Scenario: AC-1 full budget allows requests below reject threshold
      Given the nginx mock environment is reset
      And a runtime config with budget 10000 period "1d" and reject at 100
      And the runtime key is built for rule "daily_budget" and tenant "org-1"
      When I run one budget check with cost 100
      Then the budget check is allowed with action "allow" remaining 9900 usage_percent 1

    Scenario: AC-2 budget exhaustion triggers reject without charging request
      Given the nginx mock environment is reset
      And a runtime config with budget 100 period "1d" and reject at 100
      And the runtime key is built for rule "daily_budget" and tenant "org-1"
      And usage is preloaded as 100 for current period
      When I run one budget check with cost 1
      Then the budget check is rejected with reason "budget_exceeded" retry_after 85400 usage_percent 101
      And the stored usage for current period is 100

    Scenario: AC-3 period reset occurs when crossing midnight UTC
      Given the nginx mock environment is reset
      And a runtime config with budget 100 period "1d" and reject at 100
      And the runtime key is built for rule "daily_budget" and tenant "org-1"
      And usage is preloaded as 100 at now 1770163199
      And time is set to 1770163201
      When I run one budget check with cost 1
      Then the budget check is allowed with action "allow" remaining 99 usage_percent 1
      And the period key at now 1770163201 stores usage 1

    Scenario: AC-4 warn staged action triggers at 80 percent
      Given the nginx mock environment is reset
      And a runtime config with budget 1000 period "1d" and staged actions 80 warn 95 throttle 100 reject delay 200
      And the runtime key is built for rule "daily_budget" and tenant "org-1"
      And usage is preloaded as 790 for current period
      When I run one budget check with cost 10
      Then the budget check is allowed with action "warn" remaining 200 usage_percent 80
      And warning flag is true

    Scenario: AC-5 throttle staged action triggers at 95 percent
      Given the nginx mock environment is reset
      And a runtime config with budget 1000 period "1d" and staged actions 80 warn 95 throttle 100 reject delay 200
      And the runtime key is built for rule "daily_budget" and tenant "org-1"
      And usage is preloaded as 940 for current period
      When I run one budget check with cost 10
      Then the budget check is allowed with action "throttle" remaining 50 usage_percent 95
      And delay_ms is 200

    Scenario: AC-6 most severe applicable action is selected
      Given the nginx mock environment is reset
      And a runtime config with budget 1000 period "1d" and staged actions 80 warn 95 throttle 100 reject delay 200
      And the runtime key is built for rule "daily_budget" and tenant "org-1"
      And usage is preloaded as 960 for current period
      When I run one budget check with cost 1
      Then the budget check is allowed with action "throttle" remaining 39 usage_percent 96.1

    Scenario: AC-11 retry_after reflects time to next period boundary
      Given the nginx mock environment is reset
      And a runtime config with budget 100 period "1d" and reject at 100
      And the runtime key is built for rule "daily_budget" and tenant "org-1"
      And usage is preloaded as 100 at now 1770098400
      When I run one budget check with cost 1 at now 1770098400
      Then the budget check is rejected with reason "budget_exceeded" retry_after 64800 usage_percent 101

    Scenario: AC-12 atomic incr plus rollback preserves expected stored usage
      Given the nginx mock environment is reset
      And a runtime config with budget 1 period "1d" and reject at 100
      And the runtime key is built for rule "daily_budget" and tenant "org-atomic"
      When I run 2 budget checks with cost 1
      Then the last budget check action is "reject"
      And the stored usage for current period is 1

    Scenario: rollback on reject restores exact state via dict incr key minus cost
      Given the nginx mock environment is reset
      And a runtime config with budget 100 period "1d" and reject at 100
      And the runtime key is built for rule "daily_budget" and tenant "org-1"
      And usage is preloaded as 50 for current period
      When I run one budget check with cost 60
      Then the budget check is rejected with reason "budget_exceeded" retry_after 85400 usage_percent 110
      And the stored usage for current period is 50

    Scenario: AC-10 hourly boundary matches top of hour in runtime path
      Given the nginx mock environment is reset
      And a runtime config with budget 10 period "1h" and reject at 100
      And the runtime key is "cb:hourly:org-1"
      And time is set to 1770129000
      When I run one budget check with cost 1
      Then the budget check is allowed with action "allow" remaining 9 usage_percent 10
      And the period key at now 1770129000 stores usage 1

    Scenario: 5m period reset occurs on UTC five-minute boundary
      Given the nginx mock environment is reset
      And a runtime config with budget 10 period "5m" and reject at 100
      And the runtime key is "cb:five-minute:org-1"
      And usage is preloaded as 10 at now 1770129299
      And time is set to 1770129300
      When I run one budget check with cost 1
      Then the budget check is allowed with action "allow" remaining 9 usage_percent 10
      And the period key at now 1770129300 stores usage 1

    Scenario: 5m retry_after points to next five-minute boundary
      Given the nginx mock environment is reset
      And a runtime config with budget 10 period "5m" and reject at 100
      And the runtime key is "cb:five-minute:org-2"
      And usage is preloaded as 10 at now 1770129010
      When I run one budget check with cost 1 at now 1770129010
      Then the budget check is rejected with reason "budget_exceeded" retry_after 290 usage_percent 110
