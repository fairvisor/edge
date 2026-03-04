package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local descriptor = require("fairvisor.descriptor")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

runner:given("^a policy with composite limit keys for jwt, header, query, and ip$", function(ctx)
  ctx.limit_keys = {
    "jwt:org_id",
    "header:X-API-Key",
    "query:plan",
    "ip:country",
  }
end)

runner:given("^a request context with values for all descriptor sources$", function(ctx)
  ctx.request_context = {
    jwt_claims = { org_id = "acme" },
    headers = { ["X-API-Key"] = "key-123" },
    query_params = { plan = "pro" },
    ip_country = "US",
  }
end)

runner:given("^a policy with ua bot and ip asn keys$", function(ctx)
  ctx.limit_keys = { "ua:bot", "ip:asn" }
end)

runner:given("^a policy with ua bot category and ip asn keys$", function(ctx)
  ctx.limit_keys = { "ua:bot_category", "ip:asn" }
end)

runner:given("^a policy with ua bot and ua bot category keys$", function(ctx)
  ctx.limit_keys = { "ua:bot", "ua:bot_category" }
end)

runner:given('^a request context with user agent "([^"]+)" and ip asn "([^"]+)"$', function(ctx, user_agent, ip_asn)
  ctx.request_context = {
    user_agent = user_agent,
    ip_asn = ip_asn,
  }
end)

runner:given("^a policy with jwt org and query plan keys$", function(ctx)
  ctx.limit_keys = { "jwt:org_id", "query:plan" }
end)

runner:given("^a policy with ip tor and ip country keys$", function(ctx)
  ctx.limit_keys = { "ip:tor", "ip:country" }
end)

runner:given("^a request context missing query plan$", function(ctx)
  ctx.request_context = {
    jwt_claims = { org_id = "acme" },
    query_params = {},
  }
end)

runner:given('^a request context with ip tor "([^"]+)" and ip country "([^"]+)"$', function(ctx, ip_tor, ip_country)
  ctx.request_context = {
    ip_tor = ip_tor,
    ip_country = ip_country,
  }
end)

runner:when("^I validate and extract descriptors for the policy$", function(ctx)
  local ok, err = descriptor.validate_limit_keys(ctx.limit_keys)
  assert.is_true(ok, err)
  ctx.descriptors, ctx.missing_keys = descriptor.extract(ctx.limit_keys, ctx.request_context)
end)

runner:when("^I build the policy composite key$", function(ctx)
  ctx.composite_key = descriptor.build_composite_key(ctx.limit_keys, ctx.descriptors)
end)

runner:then_('^the composite key is "([^"]+)"$', function(ctx, expected)
  assert.equals(expected, ctx.composite_key)
end)

runner:then_('^descriptor "([^"]+)" is "([^"]+)"$', function(ctx, key, value)
  assert.equals(value, ctx.descriptors[key])
end)

runner:then_("^no descriptors are missing$", function(ctx)
  assert.same({}, ctx.missing_keys)
end)

runner:then_('^missing keys include only "([^"]+)"$', function(ctx, key)
  assert.same({ key }, ctx.missing_keys)
end)

runner:feature_file_relative("features/descriptor.feature")
