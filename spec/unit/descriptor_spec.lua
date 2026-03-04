package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local descriptor = require("fairvisor.descriptor")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

runner:given("^limit_keys is empty$", function(ctx)
  ctx.limit_keys = {}
end)

runner:given('^limit_keys is "([^"]+)"$', function(ctx, key)
  ctx.limit_keys = { key }
end)

runner:given("^limit_keys include jwt org and ip country$", function(ctx)
  ctx.limit_keys = { "jwt:org_id", "ip:country" }
end)

runner:given("^limit_keys include ua bot and ua bot category$", function(ctx)
  ctx.limit_keys = { "ua:bot", "ua:bot_category" }
end)

runner:given("^limit_keys include all valid source examples$", function(ctx)
  ctx.limit_keys = {
    "jwt:org_id",
    "header:X-Key",
    "query:plan",
    "ip:address",
    "ip:country",
    "ip:asn",
    "ip:tor",
    "ua:bot",
  }
end)

runner:given('^jwt claim "([^"]+)" is "([^"]*)"$', function(ctx, key, value)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.jwt_claims = ctx.request_context.jwt_claims or {}
  ctx.request_context.jwt_claims[key] = value
end)

runner:given('^jwt claim "([^"]+)" is numeric (%d+)$', function(ctx, key, value)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.jwt_claims = ctx.request_context.jwt_claims or {}
  ctx.request_context.jwt_claims[key] = tonumber(value)
end)

runner:given("^jwt claims are empty$", function(ctx)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.jwt_claims = {}
end)

runner:given('^header "([^"]+)" is "([^"]*)"$', function(ctx, key, value)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.headers = ctx.request_context.headers or {}
  ctx.request_context.headers[key] = value
end)

runner:given('^header "([^"]+)" has repeated values "([^"]+)" and "([^"]+)"$', function(ctx, key, first, second)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.headers = ctx.request_context.headers or {}
  ctx.request_context.headers[key] = { first, second }
end)

runner:given('^query parameter "([^"]+)" is "([^"]*)"$', function(ctx, key, value)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.query_params = ctx.request_context.query_params or {}
  ctx.request_context.query_params[key] = value
end)

runner:given('^IP address is "([^"]+)"$', function(ctx, value)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.ip_address = value
end)

runner:given('^IP country is "([^"]+)"$', function(ctx, value)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.ip_country = value
end)

runner:given('^IP ASN is "([^"]+)"$', function(ctx, value)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.ip_asn = value
end)

runner:given("^IP tor flag is true$", function(ctx)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.ip_tor = true
end)

runner:given('^user agent is "([^"]+)"$', function(ctx, user_agent)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.user_agent = user_agent
end)

runner:given("^user agent is nil$", function(ctx)
  ctx.request_context = ctx.request_context or {}
  ctx.request_context.user_agent = nil
end)

runner:given("^descriptors only include jwt org$", function(ctx)
  ctx.descriptors = { ["jwt:org_id"] = "acme" }
end)

runner:when("^I validate limit keys$", function(ctx)
  ctx.ok, ctx.err = descriptor.validate_limit_keys(ctx.limit_keys)
end)

runner:when("^I extract descriptors$", function(ctx)
  ctx.request_context = ctx.request_context or {}
  ctx.descriptors, ctx.missing_keys = descriptor.extract(ctx.limit_keys, ctx.request_context)
end)

runner:when("^I build the composite key$", function(ctx)
  ctx.composite = descriptor.build_composite_key(ctx.limit_keys, ctx.descriptors)
end)

runner:when("^I build a default bot index and classify the user agent$", function(ctx)
  local index = descriptor.build_bot_index(nil)
  ctx.bot_result = descriptor.classify_bot(index, ctx.request_context.user_agent)
end)

runner:when("^I build a bot index with GPTBot and ClaudeBot and classify the user agent$", function(ctx)
  local index = descriptor.build_bot_index({ "GPTBot", "ClaudeBot" })
  ctx.bot_result = descriptor.classify_bot(index, ctx.request_context.user_agent)
end)

runner:then_("^validation succeeds$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
end)

runner:then_("^validation fails$", function(ctx)
  assert.is_nil(ctx.ok)
  assert.is_truthy(ctx.err)
end)

runner:then_('^descriptor "([^"]+)" is "([^"]*)"$', function(ctx, key, value)
  assert.equals(value, ctx.descriptors[key])
end)

runner:then_("^descriptors are empty$", function(ctx)
  assert.same({}, ctx.descriptors)
end)

runner:then_("^missing keys are empty$", function(ctx)
  assert.same({}, ctx.missing_keys)
end)

runner:then_('^missing keys include only "([^"]+)"$', function(ctx, key)
  assert.same({ key }, ctx.missing_keys)
end)

runner:then_('^missing keys include "([^"]+)" and "([^"]+)"$', function(ctx, key1, key2)
  assert.same({ key1, key2 }, ctx.missing_keys)
end)

runner:then_('^composite key is "([^"]*)"$', function(ctx, expected)
  assert.equals(expected, ctx.composite)
end)

runner:then_('^bot classification is "([^"]+)"$', function(ctx, expected)
  assert.equals(expected, ctx.bot_result)
end)

runner:feature_file_relative("features/descriptor.feature")

describe("descriptor parse_key", function()
  it("splits only on the first colon", function()
    local source, name = descriptor.parse_key("header:X-Forwarded-For:extra")
    assert.equals("header", source)
    assert.equals("X-Forwarded-For:extra", name)
  end)

  it("returns nil pair for invalid input", function()
    local source, name = descriptor.parse_key("invalid")
    assert.is_nil(source)
    assert.is_nil(name)
  end)
end)

describe("descriptor ua bot cache", function()
  it("memoizes bot classification on request context", function()
    local limit_keys = { "ua:bot" }
    local request_context = {
      user_agent = "Mozilla/5.0 (compatible; GPTBot/1.0)",
    }

    local descriptors_a, missing_a = descriptor.extract(limit_keys, request_context)
    request_context.user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64) Chrome/120"
    local descriptors_b, missing_b = descriptor.extract(limit_keys, request_context)

    assert.equals("true", descriptors_a["ua:bot"])
    assert.same({}, missing_a)

    assert.equals("true", descriptors_b["ua:bot"])
    assert.same({}, missing_b)
  end)
end)

describe("descriptor validation edge cases", function()
  it("rejects non-table limit_keys", function()
    local ok, err = descriptor.validate_limit_keys("jwt:org_id")
    assert.is_nil(ok)
    assert.equals("limit_keys must be a table", err)
  end)

  it("rejects unknown source type", function()
    local ok, err = descriptor.validate_limit_keys({ "cookie:session" })
    assert.is_nil(ok)
    assert.equals("invalid limit_key format: cookie:session", err)
  end)

  it("rejects header names with colon characters", function()
    local ok, err = descriptor.validate_limit_keys({ "header:X-Forwarded-For:extra" })
    assert.is_nil(ok)
    assert.equals("invalid limit_key format: header:X-Forwarded-For:extra", err)
  end)
end)

describe("descriptor extraction edge cases", function()
  it("returns empty outputs when limit_keys is not a table", function()
    local descriptors, missing = descriptor.extract(nil, { jwt_claims = { org_id = "acme" } })
    assert.same({}, descriptors)
    assert.same({}, missing)
  end)

  it("marks empty string as missing descriptor", function()
    local descriptors, missing = descriptor.extract({ "query:plan" }, { query_params = { plan = "" } })
    assert.same({}, descriptors)
    assert.same({ "query:plan" }, missing)
  end)

  it("handles nil request_context by failing open on all keys", function()
    local descriptors, missing = descriptor.extract({ "jwt:org_id", "ip:country" }, nil)
    assert.same({}, descriptors)
    assert.same({ "jwt:org_id", "ip:country" }, missing)
  end)

  it("reads first value from multi-value query args", function()
    local descriptors, missing = descriptor.extract({ "query:plan" }, { query_params = { plan = { "pro", "free" } } })
    assert.equals("pro", descriptors["query:plan"])
    assert.same({}, missing)
  end)

  it("extracts ip country and asn when present", function()
    local descriptors, missing = descriptor.extract(
      { "ip:country", "ip:asn" },
      { ip_country = "US", ip_asn = "AS13335" }
    )

    assert.equals("US", descriptors["ip:country"])
    assert.equals("AS13335", descriptors["ip:asn"])
    assert.same({}, missing)
  end)

  it("extracts ip tor as string boolean when present", function()
    local descriptors, missing = descriptor.extract(
      { "ip:tor" },
      { ip_tor = true }
    )

    assert.equals("true", descriptors["ip:tor"])
    assert.same({}, missing)
  end)
end)

describe("descriptor composite key edge cases", function()
  it("returns empty string for empty limit_keys", function()
    assert.equals("", descriptor.build_composite_key({}, {}))
  end)

  it("coerces numeric descriptor values to strings", function()
    local composite = descriptor.build_composite_key({ "jwt:count", "ip:country" }, { ["jwt:count"] = 42, ["ip:country"] = "US" })
    assert.equals("42|US", composite)
  end)
end)

describe("descriptor bot index behavior", function()
  it("returns false classification when user agent is shorter than q-gram length", function()
    local index = descriptor.build_bot_index({ "GPTBot" })
    assert.equals("false", descriptor.classify_bot(index, "GP"))
  end)

  it("matches bot patterns case-insensitively", function()
    local index = descriptor.build_bot_index({ "GPTBot" })
    assert.equals("true", descriptor.classify_bot(index, "mozilla/5.0 (compatible; gptbot/1.0)"))
  end)

  it("returns nil for nil user agent classification", function()
    local index = descriptor.build_bot_index({ "GPTBot" })
    assert.is_nil(descriptor.classify_bot(index, nil))
  end)

  it("builds index for short patterns without crashing", function()
    local index = descriptor.build_bot_index({ "AI", "Bot" })
    assert.equals("false", descriptor.classify_bot(index, "Mozilla/5.0"))
  end)
end)

describe("descriptor parse and validation coverage", function()
  it("rejects key with missing name", function()
    local source, name = descriptor.parse_key("jwt:")
    assert.is_nil(source)
    assert.is_nil(name)
  end)

  it("rejects key with missing source", function()
    local source, name = descriptor.parse_key(":org_id")
    assert.is_nil(source)
    assert.is_nil(name)
  end)

  it("accepts alphanumeric underscore and dash names", function()
    local ok, err = descriptor.validate_limit_keys({
      "jwt:org_1",
      "header:X-Key_1",
      "query:plan-2",
    })
    assert.is_true(ok)
    assert.is_nil(err)
  end)

  it("rejects unsupported ua key names", function()
    local ok, err = descriptor.validate_limit_keys({ "ua:mobile" })
    assert.is_nil(ok)
    assert.equals("invalid limit_key format: ua:mobile", err)
  end)

  it("rejects unsupported ip key names", function()
    local ok, err = descriptor.validate_limit_keys({ "ip:city" })
    assert.is_nil(ok)
    assert.equals("invalid limit_key format: ip:city", err)
  end)
end)
