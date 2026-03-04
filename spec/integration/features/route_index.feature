Feature: Route index integration behavior
  Rule: Multiple policies and overlapping paths are returned together
    Scenario: POST chat completions matches root, v1, chat prefix, and exact policy
      Given a mixed policy bundle with exact and prefix selectors
      When I build a route index from the bundle
      Then the index build succeeds
      When I evaluate method "POST" and path "/v1/chat/completions"
      Then the matches include "policy-global"
      And the matches include "policy-v1"
      And the matches include "policy-chat"
      And the matches include "policy-chat-post"
      And the matches do not include "policy-data-get"

    Scenario: GET data matches root, v1 prefix, and GET exact policy only
      Given a mixed policy bundle with exact and prefix selectors
      When I build a route index from the bundle
      Then the index build succeeds
      When I evaluate method "GET" and path "/v1/data"
      Then the matches include "policy-global"
      And the matches include "policy-v1"
      And the matches include "policy-data-get"
      And the matches do not include "policy-chat"
      And the matches do not include "policy-chat-post"

    Scenario: GET bare v1 matches root only because /v1/ requires descendant segment
      Given a mixed policy bundle with exact and prefix selectors
      When I build a route index from the bundle
      Then the index build succeeds
      When I evaluate method "GET" and path "/v1"
      Then the matches include "policy-global"
      And the matches do not include "policy-v1"
      And the matches do not include "policy-chat"
      And the matches do not include "policy-data-get"

  Rule: Host selectors combine with global selectors
    Scenario: host-specific and global selectors both match same request
      Given a mixed policy bundle with host-specific and global selectors
      When I build a route index from the bundle
      Then the index build succeeds
      When I evaluate host "api.example.com" method "GET" and path "/v1/data"
      Then the matches include "policy-global"
      And the matches include "policy-api-host"
      And the matches do not include "policy-admin-host"

    Scenario: unknown host falls back to global selectors only
      Given a mixed policy bundle with host-specific and global selectors
      When I build a route index from the bundle
      Then the index build succeeds
      When I evaluate host "unknown.example.com" method "GET" and path "/v1/data"
      Then the matches include "policy-global"
      And the matches do not include "policy-api-host"
      And the matches do not include "policy-admin-host"
