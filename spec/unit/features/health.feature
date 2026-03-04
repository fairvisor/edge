Feature: Health and Prometheus metrics
  Rule: Health endpoints expose liveness and readiness
    Scenario: AC-1 livez returns healthy with version
      Given a new health instance
      When livez is called
      Then result is { status = "healthy", version = "0.1.0" }

    Scenario: AC-2 readyz returns not_ready before bundle load
      Given a new health instance with no bundle loaded
      When readyz is called
      Then first return is nil
      And second return is { status = "not_ready", reason = "no_policy_loaded" }

    Scenario: AC-3 readyz returns ready after bundle load
      Given a new health instance
      And set_bundle_state("v42", "abc123", 1708000000) is called
      When readyz is called
      Then result is { status = "ready", policy_version = "v42", policy_hash = "abc123", last_config_update = 1708000000 }

    Scenario: AC-12 set_bundle_state updates readyz response
      Given a health instance with initial bundle state v1
      When set_bundle_state("v2", "def456", 1708100000) is called
      And readyz is called
      Then policy_version is "v2" and policy_hash is "def456"

  Rule: Module-level API for bundle_loader compatibility
    Scenario: set_bundle_state and get_bundle_state use default instance
      Given the default health instance is used
      When module-level set_bundle_state("v99", "hash99", 1708000000) is called
      And module-level get_bundle_state is called
      Then bundle state has version "v99", hash "hash99", loaded_at 1708000000

  Rule: Metrics registry supports counters and gauges
    Scenario: AC-4 Counter registration and increment
      Given a new health instance
      And a registered counter "test_decisions_total"
      When inc is called with labels { action = "allow" } and value 1
      And inc is called again with same labels
      And render is called
      Then render includes 'test_decisions_total{action="allow"} 2'

    Scenario: AC-5 Gauge set
      Given a new health instance
      And a registered gauge "test_circuit_state"
      When set is called with labels { limit_key = "org-1" } and value 1
      And render is called
      Then render includes 'test_circuit_state{limit_key="org-1"} 1'

    Scenario: AC-6 Render includes HELP and TYPE lines
      Given a new health instance
      And a registered counter "test_decisions_total" with help "Total decisions"
      When render is called
      Then output includes '# HELP test_decisions_total Total decisions'
      And output includes '# TYPE test_decisions_total counter'

    Scenario: AC-7 Multiple label keys are sorted deterministically
      Given a new health instance
      And a counter with labels { route = "/v1", action = "reject" }
      When render is called
      Then label string is '{action="reject",route="/v1"}'

    Scenario: AC-8 Empty labels produce no label string
      Given a new health instance
      And a counter incremented with nil labels
      When render is called
      Then metric line has no braces: 'test_decisions_total 1'

    Scenario: AC-9 Label value escaping
      Given a new health instance
      And a counter with label value containing quote and backslash
      When render is called
      Then quotes are escaped as \" and backslashes as \\

    Scenario: AC-10 Duplicate registration returns error
      Given a new health instance
      And "test_decisions_total" is already registered
      When register is called again with the same name
      Then it returns nil, "metric already registered"

    Scenario: AC-11 Inc on unregistered metric lazily creates counter
      Given no metrics registered
      When inc is called for "nonexistent_metric"
      And render is called
      Then render includes 'nonexistent_metric{action="allow"} 1'
