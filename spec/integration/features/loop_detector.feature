Feature: Loop detector integration behavior
  Rule: Golden tests for threshold detection
    Scenario: RE-010 loop triggers at threshold
      Given the nginx mock environment is reset
      And a loop detection reject config with threshold 10 and window 60
      And the fingerprint is built for org "acme"
      When I run 10 loop checks
      Then the first 9 checks report no detection and increasing count
      And the 10th check reports reject with retry_after 60

    Scenario: RE-011 below threshold remains allowed
      Given the nginx mock environment is reset
      And a loop detection reject config with threshold 10 and window 60
      And the fingerprint is built for org "acme"
      When I run 9 loop checks
      Then the first 9 checks report no detection and increasing count
