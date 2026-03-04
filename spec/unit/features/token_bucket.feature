Feature: Token bucket module behavior
  Rule: Config validation
    Scenario: accepts a valid token bucket config
      Given a valid token bucket config with rate 100 and burst 200
      When I validate the config
      Then validation succeeds
      And tokens_per_second is 100

    Scenario: normalizes rps into tokens_per_second
      Given a config with rps 15 and burst 15
      When I validate the config
      Then validation succeeds
      And tokens_per_second is 15
      And rps remains 15

    Scenario: keeps tokens_per_second when both tokens_per_second and rps are present
      Given a config with tokens_per_second 20, rps 10, and burst 20
      When I validate the config
      Then validation succeeds
      And tokens_per_second is 20

    Scenario: sets default cost fields
      Given a minimal valid config with tokens_per_second 5 and burst 5
      When I validate the config
      Then validation succeeds
      And cost defaults are fixed 1 and default 1

    Scenario: rejects non-table config
      Given an invalid non-table config
      When I validate the config
      Then validation fails with error "config must be a table"

    Scenario: rejects non-token_bucket algorithm
      Given a config with algorithm "cost_budget"
      When I validate the config
      Then validation fails with error "algorithm must be token_bucket"

    Scenario: rejects missing tokens_per_second and rps
      Given a config missing rate fields and burst 200
      When I validate the config
      Then validation fails with error "tokens_per_second or rps is required"

    Scenario: rejects non-positive tokens_per_second
      Given a config with non-positive tokens_per_second 0 and burst 10
      When I validate the config
      Then validation fails with error "tokens_per_second must be a positive number"

    Scenario: rejects burst below tokens_per_second
      Given a config with tokens_per_second 20, burst 10, and cost_source "fixed"
      When I validate the config
      Then validation fails with error "burst must be >= tokens_per_second"

    Scenario: rejects invalid cost_source
      Given a config with tokens_per_second 10, burst 10, and cost_source "cookie:weight"
      When I validate the config
      Then validation fails with error "cost_source must be fixed, header:<name>, or query:<name>"

    Scenario: accepts header and query cost sources with valid names
      Then header and query cost_source names are accepted

  Rule: Key generation
    Scenario: builds key with rule name and limit key
      When I build key from rule "api_rate" and limit key "tenant-42"
      Then the built key is "tb:api_rate:tenant-42"

    Scenario: supports empty limit key
      When I build key from rule "global_limit" and limit key ""
      Then the built key is "tb:global_limit:"

  Rule: Cost resolution
    Scenario: returns fixed cost for fixed source
      Given a resolve_cost config with source "fixed" fixed_cost 10 default_cost 1
      And an empty request context
      When I resolve request cost
      Then the resolved cost is 10

    Scenario: resolves header cost when present
      Given a resolve_cost config with source "header:X-Weight" fixed_cost 1 default_cost 1
      And an empty request context
      And request headers contain "X-Weight" as "5"
      When I resolve request cost
      Then the resolved cost is 5

    Scenario: falls back to default_cost when header missing
      Given a resolve_cost config with source "header:X-Weight" fixed_cost 1 default_cost 1
      And an empty request context
      When I resolve request cost
      Then the resolved cost is 1

    Scenario: falls back to default_cost when header is non-numeric
      Given a resolve_cost config with source "header:X-Weight" fixed_cost 1 default_cost 3
      And an empty request context
      And request headers contain "X-Weight" as "abc"
      When I resolve request cost
      Then the resolved cost is 3

    Scenario: resolves query cost when present
      Given a resolve_cost config with source "query:weight" fixed_cost 1 default_cost 2
      And an empty request context
      And request query contains "weight" as "7"
      When I resolve request cost
      Then the resolved cost is 7

    Scenario: falls back for unknown source
      Given a resolve_cost config with source "unknown" fixed_cost 1 default_cost 4
      And an empty request context
      When I resolve request cost
      Then the resolved cost is 4

    Scenario: resolve_cost uses cached _cost_source_kind after validate_config for header
      Given a validated resolve config with cost_source "header:X-Weight" fixed_cost 1 default_cost 1
      And an empty request context
      And request headers contain "X-Weight" as "5"
      When I resolve request cost
      Then the resolved cost is 5

    Scenario: resolve_cost uses cached _cost_source_kind after validate_config for query
      Given a validated resolve config with cost_source "query:weight" fixed_cost 1 default_cost 2
      And an empty request context
      And request query contains "weight" as "7"
      When I resolve request cost
      Then the resolved cost is 7

    Scenario: resolve_cost without _cost_source_kind returns same result as with cache
      Given a resolve_cost config with source "header:X-Cost" fixed_cost 1 default_cost 2
      And an empty request context
      And request headers contain "X-Cost" as "3"
      When I resolve request cost
      Then the resolved cost is 3

    Scenario: ensures fixed cost fallback to 1 when non-positive
      Given a resolve_cost config with source "fixed" fixed_cost 0 default_cost 10
      And an empty request context
      When I resolve request cost
      Then the resolved cost is 1

  Rule: Runtime checks
    Scenario: allows fresh bucket requests up to burst
      Given the nginx mock environment is reset
      And a default runtime token bucket config
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      When I execute 200 runtime checks with cost 1
      Then all runtime checks are allowed with remaining tokens: 199, 198, 197, 196, 195, 194, 193, 192, 191, 190, 189, 188, 187, 186, 185, 184, 183, 182, 181, 180, 179, 178, 177, 176, 175, 174, 173, 172, 171, 170, 169, 168, 167, 166, 165, 164, 163, 162, 161, 160, 159, 158, 157, 156, 155, 154, 153, 152, 151, 150, 149, 148, 147, 146, 145, 144, 143, 142, 141, 140, 139, 138, 137, 136, 135, 134, 133, 132, 131, 130, 129, 128, 127, 126, 125, 124, 123, 122, 121, 120, 119, 118, 117, 116, 115, 114, 113, 112, 111, 110, 109, 108, 107, 106, 105, 104, 103, 102, 101, 100, 99, 98, 97, 96, 95, 94, 93, 92, 91, 90, 89, 88, 87, 86, 85, 84, 83, 82, 81, 80, 79, 78, 77, 76, 75, 74, 73, 72, 71, 70, 69, 68, 67, 66, 65, 64, 63, 62, 61, 60, 59, 58, 57, 56, 55, 54, 53, 52, 51, 50, 49, 48, 47, 46, 45, 44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 32, 31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0

    Scenario: rejects burst plus one request with retry_after 1
      Given the nginx mock environment is reset
      And a default runtime token bucket config
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      And I consume 200 runtime checks with cost 1
      When I execute one runtime check with cost 1
      Then the runtime check is rejected with remaining 0 retry_after 1 and limit 200

    Scenario: replenishes tokens after idle period
      Given the nginx mock environment is reset
      And a default runtime token bucket config
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      And I consume 200 runtime checks with cost 1
      And time advances by 1 seconds
      When I execute one runtime check with cost 1
      Then the runtime check is allowed with remaining 99 and limit 200

    Scenario: caps replenishment at burst
      Given the nginx mock environment is reset
      And a default runtime token bucket config
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      And I consume 50 runtime checks with cost 1
      And time advances by 10 seconds
      When I execute one runtime check with cost 1
      Then the runtime check is allowed with remaining 199 and limit 200

    Scenario: supports fixed weighted cost
      Given the nginx mock environment is reset
      And a runtime config with fixed_cost 10
      And the runtime key is built for rule "weighted" and tenant "tenant-42"
      When I execute one runtime check with cost 10
      Then the runtime check is allowed with remaining 190 and limit 200

    Scenario: computes retry_after from deficit
      Given the nginx mock environment is reset
      And a runtime config with tokens_per_second 50 and burst 100
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      And stored bucket has 3 tokens at current time
      When I execute one runtime check with cost 10
      Then the runtime check is rejected with remaining 0 retry_after 1 and limit 100

    Scenario: treats non-positive cost as 1
      Given the nginx mock environment is reset
      And a default runtime token bucket config
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      When I execute one runtime check with cost 0
      Then the runtime check is allowed with remaining 199 and limit 200

    Scenario: handles clock moving backward by using zero elapsed
      Given the nginx mock environment is reset
      And a runtime config with tokens_per_second 10 and burst 10
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      And I consume 1 runtime checks with cost 5
      And time moves backward by 1 seconds
      When I execute one runtime check with cost 1
      Then the runtime check is allowed with remaining 4 and limit 10

    Scenario: falls back to fresh-bucket semantics for malformed stored value
      Given the nginx mock environment is reset
      And a runtime config with tokens_per_second 10 and burst 10
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      And stored bucket value is malformed
      When I execute one runtime check with cost 1
      Then the runtime check is allowed with remaining 9 and limit 10

    Scenario: does not require config re-validation in check hot path
      Given the nginx mock environment is reset
      And an unchecked runtime config with tokens_per_second 10 and burst 10
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      When I execute one runtime check with cost 1
      Then the runtime check is allowed with remaining 9 and limit 10

    Scenario: cost greater than burst is always rejected with correct retry_after math
      Given the nginx mock environment is reset
      And a runtime config with tokens_per_second 10 and burst 100
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      When I execute one runtime check with cost 150
      Then the runtime check is rejected with remaining 0 retry_after 5 and limit 100

    Scenario: refill timing with large elapsed interval caps at burst
      Given the nginx mock environment is reset
      And a runtime config with tokens_per_second 1 and burst 50
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      And I consume 50 runtime checks with cost 1
      And time advances by 10000 seconds
      When I execute one runtime check with cost 1
      Then the runtime check is allowed with remaining 49 and limit 50

    Scenario: operates with one get and one set per check call
      Given a counting shared_dict is used
      And a runtime config with tokens_per_second 10 and burst 10
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      When I execute one runtime check on the counting dict with cost 1
      Then the counting dict recorded get 1 and set 1

    Scenario: ignores shared_dict set return value and still returns decision
      Given a set-failing shared_dict is used
      And a runtime config with tokens_per_second 10 and burst 10
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      When I execute one runtime check on the set-failing dict with cost 1
      Then the runtime check is allowed with remaining 9 and limit 10

    Scenario: returns only decision fields, keeping metrics out of limiter
      Given the nginx mock environment is reset
      And a runtime config with tokens_per_second 10 and burst 10
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      When I execute one runtime check with cost 1
      Then the runtime decision fields include allowed remaining and limit only

  Rule: Result table isolation (concurrency safety)
    Scenario: two consecutive check calls return independent result tables
      Given the nginx mock environment is reset
      And a default runtime token bucket config
      And the runtime key is built for rule "api_rate" and tenant "tenant-42"
      When I execute one runtime check with cost 1 and store result as first result
      And I execute one runtime check with cost 1 and store result as second result
      And I mutate the first result allowed to false and remaining to 999
      Then the first and second results are different tables
      And the second result remaining is unchanged
