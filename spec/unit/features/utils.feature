Feature: Utils (ISO 8601 UTC timestamp parsing)
  Rule: Valid format returns epoch
    Scenario: valid UTC string returns epoch and nil error
      Given a valid ISO8601 string "2026-02-03T14:00:00Z"
      When I parse the timestamp
      Then parse succeeds with a number epoch
      And the error is nil

    Scenario: epoch round-trips to same string
      Given a valid ISO8601 string "2020-01-15T00:00:00Z"
      When I parse the timestamp
      Then parse succeeds with a number epoch
      When I format the epoch back to ISO8601 UTC
      Then the result equals "2020-01-15T00:00:00Z"

  Rule: Invalid input returns nil and error
    Scenario: nil input returns timestamp must be a string
      Given the input is nil
      When I parse the timestamp
      Then parse fails
      And the error is "timestamp must be a string"

    Scenario: non-string input returns timestamp must be a string
      Given the input is a number
      When I parse the timestamp
      Then parse fails
      And the error is "timestamp must be a string"

    Scenario: wrong format returns timestamp must be ISO8601 UTC
      Given the input string is "2026-02-03 14:00:00"
      When I parse the timestamp
      Then parse fails
      And the error is "timestamp must be ISO8601 UTC"

    Scenario: invalid month returns timestamp is invalid
      Given the input string is "2026-13-01T12:00:00Z"
      When I parse the timestamp
      Then parse fails
      And the error is "timestamp is invalid"

    Scenario: invalid day returns timestamp is invalid
      Given the input string is "2026-02-30T12:00:00Z"
      When I parse the timestamp
      Then parse fails
      And the error is "timestamp is invalid"

    Scenario: invalid time returns timestamp is invalid
      Given the input string is "2026-02-03T25:00:00Z"
      When I parse the timestamp
      Then parse fails
      And the error is "timestamp is invalid"
