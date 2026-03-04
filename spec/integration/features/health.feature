Feature: Health module integration behavior
  Rule: Bundle lifecycle updates readiness while metrics remain available
    Scenario: Bundle reload replaces readiness metadata
      Given a fresh health and metrics registry
      And the bundle is loaded as version v1
      And the bundle is reloaded as version v2
      When readiness is checked
      Then readiness returns ready for v2 metadata

    Scenario: Metrics lifecycle supports multiple metric families in one render
      Given a fresh health and metrics registry
      And standard metrics are registered
      And decision and breaker metrics are emitted
      When metrics are rendered
      Then render output includes deterministic series and metadata lines

  Rule: Constructor options affect endpoint responses
    Scenario: Custom edge version is reflected by liveness
      Given a health instance configured with edge version v9.9.9
      When liveness is checked
      Then liveness reports the configured edge version
