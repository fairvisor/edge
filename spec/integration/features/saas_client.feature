Feature: SaaS protocol client contract integration
  Rule: Protocol contract tests CT-001 through CT-004
    Scenario: CT-001 Heartbeat payload contract
      Given the integration nginx mock is reset
      And a SaaS client integration fixture
      And registration and heartbeat are accepted
      When I initialize the SaaS client
      And I run one heartbeat tick
      Then initialization succeeds in integration
      And CT-001 heartbeat contract payload contains edge identity and policy hash

    Scenario: CT-002 Config pull and ack contract
      Given the integration nginx mock is reset
      And a SaaS client integration fixture
      And heartbeat indicates a config update and config endpoint returns new bundle
      When I initialize the SaaS client
      And I run one heartbeat tick
      Then initialization succeeds in integration
      And CT-002 config contract applies bundle and sends ack

    Scenario: CT-003 Event delivery contract with idempotency
      Given the integration nginx mock is reset
      And a SaaS client integration fixture
      And registration succeeds and events endpoint accepts a batch
      When I initialize the SaaS client
      And I queue one event and trigger flush_events
      Then initialization succeeds in integration
      And CT-003 events contract sends idempotent batch delivery

    Scenario: CT-004 Circuit breaker contract on repeated SaaS failures
      Given the integration nginx mock is reset
      And a SaaS client integration fixture
      And registration succeeds and heartbeats fail 5 times
      When I initialize the SaaS client
      And I run 5 heartbeat ticks
      Then initialization succeeds in integration
      And CT-004 circuit opens and reachability metric is updated
