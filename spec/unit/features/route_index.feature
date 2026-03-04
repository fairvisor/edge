Feature: Route matching engine
  Rule: Exact and prefix path behavior
    Scenario: AC-1 pathExact matches only exact path
      Given a single policy "policy-exact" with pathExact "/v1/data"
      When I build the route index
      Then build succeeds
      When I match method "GET" and path "/v1/data"
      Then the result contains only policy "policy-exact"
      When I match method "GET" and path "/v1/data/sub"
      Then the result is empty
      When I match method "GET" and path "/v1/dat"
      Then the result is empty

    Scenario: AC-2 pathPrefix matches paths starting with prefix
      Given a single policy "policy-prefix" with pathPrefix "/v1/"
      When I build the route index
      Then build succeeds
      When I match method "GET" and path "/v1/data"
      Then the result contains only policy "policy-prefix"
      When I match method "GET" and path "/v1/chat/completions"
      Then the result contains only policy "policy-prefix"
      When I match method "GET" and path "/v2/data"
      Then the result is empty

    Scenario: AC-3 pathPrefix /v1/ does not match /v1
      Given a single policy "policy-prefix" with pathPrefix "/v1/"
      When I build the route index
      Then build succeeds
      When I match method "GET" and path "/v1"
      Then the result is empty

  Rule: Method semantics
    Scenario: AC-4 method filtering with specific methods
      Given a single policy "policy-post" with pathExact "/v1/data" and methods "POST"
      When I build the route index
      Then build succeeds
      When I match method "POST" and path "/v1/data"
      Then the result contains only policy "policy-post"
      When I match method "GET" and path "/v1/data"
      Then the result is empty

    Scenario: AC-5 wildcard method matching when methods omitted
      Given a single policy "policy-wildcard" with pathExact "/v1/data" and no methods
      When I build the route index
      Then build succeeds
      When I match method "GET" and path "/v1/data"
      Then the result contains only policy "policy-wildcard"
      When I match method "DELETE" and path "/v1/data"
      Then the result contains only policy "policy-wildcard"

  Rule: Multiple policy matching
    Scenario: AC-6 multiple policies match the same request
      Given a policy "policy-exact" with pathExact "/v1/data" and a policy "policy-prefix" with pathPrefix "/v1/"
      When I build the route index
      Then build succeeds
      When I match method "GET" and path "/v1/data"
      Then the result contains both policies "policy-exact" and "policy-prefix"

    Scenario: AC-7 overlapping prefixes
      Given a policy "policy-a" with pathPrefix "/v1/" and a policy "policy-b" with pathPrefix "/v1/chat/"
      When I build the route index
      Then build succeeds
      When I match method "GET" and path "/v1/chat/completions"
      Then the result contains both policies "policy-a" and "policy-b"
      When I match method "GET" and path "/v1/data"
      Then the result contains only policy "policy-a"

    Scenario: AC-8 no policies means no matches
      Given an empty policy set
      When I build the route index
      Then build succeeds
      When I match method "GET" and path "/any/path"
      Then the result is empty

    Scenario: identical policy matched by exact and prefix is returned once
      Given a single policy "policy-single" with both pathExact "/v1/data" and pathPrefix "/v1/"
      When I build the route index
      Then build succeeds
      When I match method "GET" and path "/v1/data"
      Then the result contains only policy "policy-single"

  Rule: Benchmarks and root behavior
    Scenario: AC-9 build benchmark for two hundred routes
      Given fifty policies with two exact and two prefix routes each
      When I build the route index
      Then build succeeds
      And build time benchmark is recorded

    Scenario: AC-10 lookup benchmark for repeated match calls
      Given fifty policies with two exact and two prefix routes each
      When I build the route index
      Then build succeeds
      When I run ten thousand lookups for GET /v1/svc1/a
      Then lookup time benchmark is recorded

    Scenario: AC-11 root prefix slash matches all paths
      Given a single policy "policy-root-prefix" with pathPrefix "/"
      When I build the route index
      Then build succeeds
      When I match method "GET" and path "/anything/at/all"
      Then the result contains only policy "policy-root-prefix"

    Scenario: AC-12 root exact slash matches only root
      Given a single policy "policy-root-exact" with pathExact "/"
      When I build the route index
      Then build succeeds
      When I match method "GET" and path "/"
      Then the result contains only policy "policy-root-exact"
      When I match method "GET" and path "/v1"
      Then the result is empty

    Scenario: AC-13 path matching is case-sensitive
      Given a single policy "policy-case" with pathExact "/v1/Data"
      When I build the route index
      Then build succeeds
      When I match method "GET" and path "/v1/Data"
      Then the result contains only policy "policy-case"
      When I match method "GET" and path "/v1/data"
      Then the result is empty

  Rule: Input contract for match
    Scenario: empty path returns no matches
      Given a single policy "policy-exact" with pathExact "/v1/data"
      When I build the route index
      Then build succeeds
      When I match method "GET" and path ""
      Then the result is empty

  Rule: Host selector behavior
    Scenario: host-specific and host-agnostic selectors merge deterministically
      Given a host-scoped and a host-agnostic policy for /v1/
      When I build the route index
      Then build succeeds
      When I match host "api.example.com" method "GET" and path "/v1/data"
      Then the result contains both policies "policy-host" and "policy-global"

    Scenario: host-specific selector does not match other hosts
      Given a host-scoped and a host-agnostic policy for /v1/
      When I build the route index
      Then build succeeds
      When I match host "admin.example.com" method "GET" and path "/v1/data"
      Then the result contains only policy "policy-global"

    Scenario: host matching is case-insensitive and ignores port
      Given a host policy with uppercase host and port
      When I build the route index
      Then build succeeds
      When I match host "api.example.com:443" method "GET" and path "/v1/data"
      Then the result contains only policy "policy-host"

    Scenario: host matching ignores trailing dot in request host
      Given a host-scoped and a host-agnostic policy for /v1/
      When I build the route index
      Then build succeeds
      When I match host "api.example.com." method "GET" and path "/v1/data"
      Then the result contains both policies "policy-host" and "policy-global"

  Rule: Build tolerance for invalid selectors
    Scenario: policies without valid paths are skipped
      Given a policy missing both path selectors
      When I build the route index
      Then build succeeds
      When I match method "GET" and path "/v1/data"
      Then the result is empty
