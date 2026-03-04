Feature: Descriptor extraction and claim resolution
  Rule: Validate and extract descriptors
    Scenario: AC-1 extract JWT claim
      Given limit_keys is "jwt:org_id"
      And jwt claim "org_id" is "acme"
      When I extract descriptors
      Then descriptor "jwt:org_id" is "acme"
      And missing keys are empty

    Scenario: AC-2 composite key with multiple sources
      Given limit_keys include jwt org and ip country
      And jwt claim "org_id" is "acme"
      And IP country is "US"
      When I extract descriptors
      And I build the composite key
      Then composite key is "acme|US"

    Scenario: AC-3 missing descriptor key is fail-open input
      Given limit_keys is "jwt:org_id"
      And jwt claims are empty
      When I extract descriptors
      Then descriptors are empty
      And missing keys include only "jwt:org_id"

    Scenario: AC-6 IP address extraction
      Given limit_keys is "ip:address"
      And IP address is "1.2.3.4"
      When I extract descriptors
      Then descriptor "ip:address" is "1.2.3.4"

    Scenario: AC-6b IP tor extraction as boolean selector
      Given limit_keys is "ip:tor"
      And IP tor flag is true
      When I extract descriptors
      Then descriptor "ip:tor" is "true"
      And missing keys are empty

    Scenario: AC-7 header extraction from named key
      Given limit_keys is "header:X-API-Key"
      And header "X-API-Key" is "abc123"
      When I extract descriptors
      Then descriptor "header:X-API-Key" is "abc123"

    Scenario: AC-7b header limit_key with hyphens matches OpenResty normalized key with underscores
      Given limit_keys is "header:x-e2e-key"
      And header "x_e2e_key" is "exhaust-abc123"
      When I extract descriptors
      Then descriptor "header:x-e2e-key" is "exhaust-abc123"
      And missing keys are empty

    Scenario: AC-8 query parameter extraction
      Given limit_keys is "query:plan"
      And query parameter "plan" is "pro"
      When I extract descriptors
      Then descriptor "query:plan" is "pro"

    Scenario: AC-12 empty user agent yields missing ua bot
      Given limit_keys is "ua:bot"
      And user agent is nil
      When I extract descriptors
      Then descriptors are empty
      And missing keys include only "ua:bot"

    Scenario: AC-13 descriptor values are always strings
      Given limit_keys is "jwt:count"
      And jwt claim "count" is numeric 42
      When I extract descriptors
      Then descriptor "jwt:count" is "42"

    Scenario: AC-14 composite key uses empty string for missing values
      Given limit_keys include jwt org and ip country
      And descriptors only include jwt org
      When I build the composite key
      Then composite key is "acme|"

  Rule: Key validation and bot detection
    Scenario: AC-4 known bot user agent is detected
      Given user agent is "Mozilla/5.0 (compatible; GPTBot/1.0)"
      When I build a default bot index and classify the user agent
      Then bot classification is "true"

    Scenario: AC-5 non-bot user agent is not detected
      Given user agent is "Mozilla/5.0 (Windows NT 10.0; Win64) Chrome/120"
      When I build a default bot index and classify the user agent
      Then bot classification is "false"

    Scenario: AC-5b GPTBot category is extracted as ai_crawler
      Given limit_keys is "ua:bot_category"
      And user agent is "Mozilla/5.0 (compatible; GPTBot/1.0)"
      When I extract descriptors
      Then descriptor "ua:bot_category" is "ai_crawler"
      And missing keys are empty

    Scenario: AC-5c browser user agent category is missing
      Given limit_keys is "ua:bot_category"
      And user agent is "Mozilla/5.0 (Windows NT 10.0; Win64) Chrome/120"
      When I extract descriptors
      Then descriptors are empty
      And missing keys include only "ua:bot_category"

    Scenario: AC-5d Chrome user agent is not classified as bot
      Given user agent is "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
      When I build a default bot index and classify the user agent
      Then bot classification is "false"

    Scenario: AC-5e Safari user agent is not classified as bot
      Given user agent is "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Safari/605.1.15"
      When I build a default bot index and classify the user agent
      Then bot classification is "false"

    Scenario: AC-5f Firefox user agent is not classified as bot
      Given user agent is "Mozilla/5.0 (X11; Linux x86_64; rv:123.0) Gecko/20100101 Firefox/123.0"
      When I build a default bot index and classify the user agent
      Then bot classification is "false"

    Scenario: AC-5g GPTBot category is ai_crawler
      Given limit_keys is "ua:bot_category"
      And user agent is "Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)"
      When I extract descriptors
      Then descriptor "ua:bot_category" is "ai_crawler"
      And missing keys are empty

    Scenario: AC-5h ChatGPT-User category is ai_assistant_user
      Given limit_keys is "ua:bot_category"
      And user agent is "Mozilla/5.0 (compatible; ChatGPT-User/1.0; +https://openai.com/bot)"
      When I extract descriptors
      Then descriptor "ua:bot_category" is "ai_assistant_user"
      And missing keys are empty

    Scenario: AC-5i Googlebot category is search_engine
      Given limit_keys is "ua:bot_category"
      And user agent is "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
      When I extract descriptors
      Then descriptor "ua:bot_category" is "search_engine"
      And missing keys are empty

    Scenario: AC-5j Bingbot category is search_engine
      Given limit_keys is "ua:bot_category"
      And user agent is "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)"
      When I extract descriptors
      Then descriptor "ua:bot_category" is "search_engine"
      And missing keys are empty

    Scenario: AC-5k bot category implies ua bot true
      Given limit_keys include ua bot and ua bot category
      And user agent is "Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)"
      When I extract descriptors
      Then descriptor "ua:bot" is "true"
      And descriptor "ua:bot_category" is "ai_crawler"
      And missing keys are empty

    Scenario: AC-9 invalid key format is rejected
      Given limit_keys is "invalid_format"
      When I validate limit keys
      Then validation fails

    Scenario: AC-10 all valid source keys are accepted
      Given limit_keys include all valid source examples
      When I validate limit keys
      Then validation succeeds

    Scenario: AC-11 anchor prefilter finds and verifies candidates
      Given user agent is "something ClaudeBot something"
      When I build a bot index with GPTBot and ClaudeBot and classify the user agent
      Then bot classification is "true"

    Scenario: Empty limit key list returns empty outputs
      Given limit_keys is empty
      When I extract descriptors
      Then descriptors are empty
      And missing keys are empty

    Scenario: Multi-value header extraction uses first value
      Given limit_keys is "header:X-Forwarded-For"
      And header "X-Forwarded-For" has repeated values "1.1.1.1" and "2.2.2.2"
      When I extract descriptors
      Then descriptor "header:X-Forwarded-For" is "1.1.1.1"

    Scenario: Header lookup is case-insensitive
      Given limit_keys is "header:X-API-Key"
      And header "x-api-key" is "secret"
      When I extract descriptors
      Then descriptor "header:X-API-Key" is "secret"
