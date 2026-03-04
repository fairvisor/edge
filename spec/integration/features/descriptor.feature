Feature: Descriptor extraction integration behavior
  Rule: Multi-source descriptor extraction composes deterministic keys
    Scenario: Builds a full composite key from mixed descriptor sources
      Given a policy with composite limit keys for jwt, header, query, and ip
      And a request context with values for all descriptor sources
      When I validate and extract descriptors for the policy
      And I build the policy composite key
      Then descriptor "jwt:org_id" is "acme"
      And descriptor "header:X-API-Key" is "key-123"
      And descriptor "query:plan" is "pro"
      And descriptor "ip:country" is "US"
      And no descriptors are missing
      And the composite key is "acme|key-123|pro|US"

    Scenario: UA bot descriptor and IP ASN are extracted together
      Given a policy with ua bot and ip asn keys
      And a request context with user agent "Mozilla/5.0 (compatible; GPTBot/1.0)" and ip asn "AS13335"
      When I validate and extract descriptors for the policy
      And I build the policy composite key
      Then descriptor "ua:bot" is "true"
      And descriptor "ip:asn" is "AS13335"
      And no descriptors are missing
      And the composite key is "true|AS13335"

    Scenario: UA bot category and IP ASN are extracted together
      Given a policy with ua bot category and ip asn keys
      And a request context with user agent "Mozilla/5.0 (compatible; GPTBot/1.0)" and ip asn "AS13335"
      When I validate and extract descriptors for the policy
      And I build the policy composite key
      Then descriptor "ua:bot_category" is "ai_crawler"
      And descriptor "ip:asn" is "AS13335"
      And no descriptors are missing
      And the composite key is "ai_crawler|AS13335"

    Scenario: UA bot category implies ua bot in the same extraction
      Given a policy with ua bot and ua bot category keys
      And a request context with user agent "Mozilla/5.0 (compatible; GPTBot/1.0)" and ip asn "AS13335"
      When I validate and extract descriptors for the policy
      And I build the policy composite key
      Then descriptor "ua:bot" is "true"
      And descriptor "ua:bot_category" is "ai_crawler"
      And no descriptors are missing
      And the composite key is "true|ai_crawler"

    Scenario: Missing descriptors propagate into missing list and empty composite segments
      Given a policy with jwt org and query plan keys
      And a request context missing query plan
      When I validate and extract descriptors for the policy
      And I build the policy composite key
      Then descriptor "jwt:org_id" is "acme"
      And missing keys include only "query:plan"
      And the composite key is "acme|"

    Scenario: IP tor selector is extracted and participates in composite key
      Given a policy with ip tor and ip country keys
      And a request context with ip tor "true" and ip country "DE"
      When I validate and extract descriptors for the policy
      And I build the policy composite key
      Then descriptor "ip:tor" is "true"
      And descriptor "ip:country" is "DE"
      And no descriptors are missing
      And the composite key is "true|DE"
