Feature: Decision API unit behavior
  Rule: JWT payload and request context
    Scenario: Decodes a valid JWT payload
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And headers include "Authorization" as "Bearer a.eyJzdWIiOiJ1c2VyLTEiLCJyb2xlIjoiYWRtaW4ifQ.c"
      When I decode the jwt payload from authorization header
      Then jwt claims contain sub "user-1" and role "admin"
      And the test cleanup restores globals

    Scenario: Returns nil claims for malformed JWT
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And headers include "Authorization" as "Bearer not-a-jwt"
      When I decode the jwt payload from authorization header
      Then jwt claims are nil
      And the test cleanup restores globals

    Scenario: BUG-6 JWT payload with nested JSON in claims is decoded by fallback
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And headers include "Authorization" with JWT containing nested claims
      When I decode the jwt payload from authorization header
      Then jwt claims contain sub "user-nested"
      And jwt claims contain nested realm_access with roles "a" and "b"
      And the test cleanup restores globals

    Scenario: Uses X-Original headers in decision service mode
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And request method is "GET" and path is "/v1/decision"
      And headers include "X-Original-Method" as "POST"
      And headers include "X-Original-URI" as "/v1/data"
      And headers include "X-Original-Host" as "API.EXAMPLE.COM:443"
      And headers include "User-Agent" as "agent-a"
      And client ip is "10.0.0.5"
      And headers include "Authorization" as "Bearer a.eyJwbGFuIjoicHJvIiwidXNlcl9pZCI6NDJ9.c"
      When I build request context
      Then request context method is "POST" and path is "/v1/data"
      And request context host is "api.example.com"
      And request context has user agent "agent-a" and client ip "10.0.0.5"
      And request context includes jwt claim plan "pro"
      And the test cleanup restores globals

    Scenario: Builds ip tor selector from nginx variable
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And nginx tor exit variable is "1"
      When I build request context
      Then request context ip tor is "true"
      And the test cleanup restores globals

    Scenario: Normalizes X-Original-Host with trailing dot
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And headers include "X-Original-Host" as "API.EXAMPLE.COM."
      When I build request context
      Then request context host is "api.example.com"
      And the test cleanup restores globals

    Scenario: Uses request method and uri in reverse proxy mode
      Given the decision api dependencies are initialized
      And the mode is "reverse_proxy" and retry jitter is "true"
      And request method is "PATCH" and path is "/items/42"
      And headers include "X-Original-Method" as "DELETE"
      And headers include "X-Original-URI" as "/ignored"
      When I build request context
      Then request context method is "PATCH" and path is "/items/42"
      And request context host is "edge.internal"
      And the test cleanup restores globals

  Rule: Access phase decision mapping
    Scenario: Returns 503 when no bundle exists
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And no bundle is currently loaded
      When I run the access handler
      Then the request is rejected with status 503
      And the test cleanup restores globals

    Scenario: Allow decision in decision service mode sets headers and proceeds
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And the rule engine decision is allow with headers limit "200" remaining "150" reset "1"
      When I run the access handler
      Then the access phase proceeds without exiting
      And response header "RateLimit-Limit" is "200"
      And response header "RateLimit-Remaining" is "150"
      And response header "RateLimit-Reset" is "1"
      And one decision metric is emitted for action "allow" and policy "policy-a"
      And the bundle and context were passed to rule engine
      And the test cleanup restores globals

    Scenario: Reject decision sets reason and deterministic jittered retry-after
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 10
      When I run the access handler
      Then the request is rejected with status 429
      And retry after header is between 10 and 15
      And one decision metric is emitted for action "reject" and policy "policy-r"
      And the test cleanup restores globals

    Scenario: Reject decisions emit retry-after bucket metric
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 10
      When I run the access handler
      Then the request is rejected with status 429
      And retry after bucket metric is emitted for bucket "le_30"
      And the test cleanup restores globals

    Scenario: Jitter also applies when Retry-After is already present in decision headers
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with header retry_after 10 and reason "rate_limit_exceeded"
      When I run the access handler
      Then retry after header is between 10 and 15
      And the test cleanup restores globals

    Scenario: Budget exceeded retry-after is jittered but capped by base window
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "budget_exceeded" and retry_after 10
      When I run the access handler
      Then retry after header is between 5 and 10
      And the test cleanup restores globals

    Scenario: Retry-After jitter is deterministic for equivalent rejects
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 10
      When I run the access handler twice
      Then both retry after headers are equal
      And the test cleanup restores globals

    Scenario: Retry-After jitter differs across different clients
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 10
      When I run the access handler for clients "10.0.0.1" and "10.0.0.2"
      Then retry after headers are different
      And the test cleanup restores globals

    Scenario: Jitter property holds for many clients
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 10
      When I collect retry after samples for clients "10.0.0.1,10.0.0.2,10.0.0.3,10.0.0.4"
      Then retry after jitter is stable per client and diversified across clients
      And the test cleanup restores globals

    Scenario: Decision API emits namespaced metric without legacy duplication
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And the rule engine decision is allow with headers limit "200" remaining "150" reset "1"
      When I run the access handler
      Then one decision metric is emitted for action "allow" and policy "policy-a"
      And legacy fairvisor decisions metric is not emitted
      And the test cleanup restores globals

    Scenario: Reject response includes all rate limit and fairvisor headers
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 10
      When I run the access handler
      Then the request is rejected with status 429
      And response includes all rate limit and fairvisor headers on reject
      And the test cleanup restores globals

    Scenario: Reverse proxy allow buffers headers for header filter
      Given the decision api dependencies are initialized
      And the mode is "reverse_proxy" and retry jitter is "true"
      And the rule engine decision is throttle with delay_ms 250
      When I run the access handler
      Then the access phase proceeds without exiting
      And throttle delay sleep is 0.25 seconds
      And the reverse proxy headers are buffered in ngx ctx
      When I run the header filter handler
      Then header filter copies buffered header "RateLimit-Limit" with value "25"
      And header filter copies buffered header "RateLimit-Remaining" with value "24"
      And the test cleanup restores globals

    Scenario: Shadow mode allow logs mode and does not reject
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And the rule engine decision is allow in shadow mode
      When I run the access handler
      Then the access phase proceeds without exiting
      And shadow mode log entry is emitted
      And the test cleanup restores globals
