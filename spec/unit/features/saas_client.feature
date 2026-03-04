Feature: SaaS protocol client unit behavior
  Rule: Initialization and recurring communication
    Scenario: Initialization registers timers and performs registration
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      When the client is initialized
      Then initialization succeeds
      And two recurring timers are registered at heartbeat 5 and event flush 60
      And the register endpoint is called once with bearer auth

    Scenario: BUG-5 init fails when registration fails and client stays uninitialized
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration fails with transport error
      When the client is initialized
      Then initialization fails
      And queue_event returns not initialized error

    Scenario: Heartbeat config hint triggers conditional pull and ack
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And bundle_loader starts with hash "base-hash" and version "v1"
      And default bundle_loader and health dependencies
      And registration succeeds
      And heartbeat succeeds with config update available
      And config pull returns 200 with bundle hash "hash-new" and version "v2"
      And the client is initialized
      When the heartbeat timer callback runs
      Then a conditional config pull includes If-None-Match with current hash
      And the bundle is applied and acked as applied

    Scenario: Manual pull returns early on not modified
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And config pull returns 304
      And the client is initialized
      When I trigger pull_config manually
      Then manual pull succeeds with no bundle load

  Rule: Circuit breaker and retries
    Scenario: Circuit opens after five failures and closes after half-open probe successes
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And config poll interval is 999999 seconds
      And heartbeat returns retriable failure 5 times
      And heartbeat succeeds 2 times
      And the client is initialized
      When the heartbeat timer callback runs 5 times
      Then the circuit state becomes disconnected
      And reachable metric is set to 0
      Given time advances by 30 seconds
      When the heartbeat timer callback runs
      Then the circuit state becomes half_open
      When the heartbeat timer callback runs
      Then the circuit state becomes connected
      And reachable metric is set to 1

    Scenario: Exponential backoff suppresses immediate retry after failure
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And heartbeat returns retriable failure 1 times
      And heartbeat succeeds 1 times
      And the client is initialized
      When the heartbeat timer callback runs
      Then backoff suppresses immediate retry and allows retry after 2.1 seconds

    Scenario: Non-retriable heartbeat status does not disconnect edge
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And heartbeat responds with non-retriable status 401
      And the client is initialized
      When the heartbeat timer callback runs
      Then the circuit state becomes connected

  Rule: Event buffering and delivery
    Scenario: Events are batched with idempotency key and success metric
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And events endpoint accepts one batch
      And the client is initialized
      And I queue events with ids: 1, 2
      When the event flush timer callback runs
      Then the event batch uses an Idempotency-Key header
      And events_sent_total has one success increment

    Scenario: Event failures keep buffered events and count error
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And events endpoint fails with status 500
      And the client is initialized
      And I queue events with ids: 10, 11
      When the event flush timer callback runs
      Then events_sent_total has one error increment

    Scenario: Buffer overflow drops oldest events first
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And events endpoint accepts one batch
      And events endpoint accepts one batch
      And the client is initialized
      And I queue events with ids: 1, 2, 3, 4
      When I force flush events
      Then buffer overflow keeps only newest events and flushes 3 events total

    Scenario: Clock skew detection is attached to events payloads
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And heartbeat succeeds with no update and server time skew of 20 seconds
      And events endpoint accepts one batch
      And the client is initialized
      And I queue events with ids: 55
      When the heartbeat timer callback runs
      And the event flush timer callback runs
      Then the events payload flags clock skew
