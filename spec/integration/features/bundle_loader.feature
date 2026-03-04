Feature: Bundle loader integration
  Rule: Load, apply, and expose health state
    Scenario: full cycle from payload to active state
      Given the integration environment is reset
      And a valid bundle payload at version 101
      When I compile the payload with current version nil
      Then the compiled payload is ready
      When I apply the compiled payload
      Then the bundle is active at version 101
      And ready state is updated with version 101

  Rule: Hot reload integration
    Scenario: timer callback loads file and swaps active bundle
      Given the integration environment is reset
      And a file bundle payload at version 202
      When I initialize file hot reload every 5 seconds
      Then the timer is registered once
      When I execute the first timer callback
      Then the bundle is active at version 202
      And ready state is updated with version 202
