package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local ok_cjson_safe, cjson_safe = pcall(require, "cjson.safe")
local ok_cjson, cjson = false, nil
if not ok_cjson_safe then
  ok_cjson, cjson = pcall(require, "cjson")
end
local utils = require("fairvisor.utils")
local json_fallback = not ok_cjson_safe and not ok_cjson and utils.get_json() or nil

local function _json_decode(payload)
  if ok_cjson_safe then
    return cjson_safe.decode(payload)
  end
  if ok_cjson then
    local ok, v = pcall(cjson.decode, payload)
    return ok and v or nil
  end
  if json_fallback then
    local v, _ = json_fallback.decode(payload)
    return v
  end
  return nil
end

local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")
local mock_bundle = require("helpers.mock_bundle")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _reload_modules()
  package.loaded["fairvisor.bundle_loader"] = nil
  package.loaded["fairvisor.health"] = nil
  package.loaded["fairvisor.route_index"] = nil
  package.loaded["fairvisor.descriptor"] = nil
  package.loaded["fairvisor.kill_switch"] = nil
  package.loaded["fairvisor.cost_budget"] = nil
  package.loaded["fairvisor.llm_limiter"] = nil

  return require("fairvisor.bundle_loader"), require("fairvisor.health")
end

runner:given("^the bundle loader environment is reset$", function(ctx)
  ctx.env = mock_ngx.setup_ngx()
  ctx.loader, ctx.health = _reload_modules()
  ctx.signing_key = "unit-test-signing-key"
end)

runner:given("^a valid unsigned bundle payload$", function(ctx)
  ctx.bundle = mock_bundle.new_bundle({ bundle_version = 42 })
  ctx.payload = mock_bundle.encode(ctx.bundle)
end)

runner:given("^a valid signed bundle payload$", function(ctx)
  ctx.bundle = mock_bundle.new_bundle({ bundle_version = 42 })
  local payload = mock_bundle.encode(ctx.bundle)
  ctx.signed_payload = mock_bundle.sign(payload, ctx.signing_key)
end)

runner:given("^an invalid signed bundle payload$", function(ctx)
  ctx.bundle = mock_bundle.new_bundle({ bundle_version = 42 })
  local payload = mock_bundle.encode(ctx.bundle)
  ctx.signed_payload = mock_bundle.invalid_signature_payload(payload, ctx.signing_key)
end)

runner:given("^current version is (%d+)$", function(ctx, version)
  ctx.current_version = tonumber(version)
end)

runner:given("^the current version is nil$", function(ctx)
  ctx.current_version = nil
end)

runner:given("^current version is nil$", function(ctx)
  ctx.current_version = nil
end)

runner:given("^the bundle version is (%d+)$", function(ctx, version)
  ctx.bundle.bundle_version = tonumber(version)
  ctx.payload = mock_bundle.encode(ctx.bundle)
end)

runner:given("^the bundle has malformed json$", function(ctx)
  ctx.payload = "{bad json"
end)

runner:given("^the bundle contains one invalid policy out of three$", function(ctx)
  local valid_policy_a = mock_bundle.new_bundle().policies[1]
  local valid_policy_b = mock_bundle.new_bundle({
    policies = {
      {
        id = "policy-second",
        spec = {
          selector = { pathPrefix = "/v2/", methods = { "GET" } },
          mode = "enforce",
          rules = {
            {
              name = "second-rate-limit",
              limit_keys = { "jwt:org_id" },
              algorithm = "token_bucket",
              algorithm_config = { tokens_per_second = 20, burst = 40 },
            },
          },
        },
      },
    },
  }).policies[1]
  local invalid_policy = {
    id = "policy-invalid",
    spec = {
      selector = { pathPrefix = "/invalid", methods = { "GET" } },
      rules = {
        {
          name = "bad-rule",
          limit_keys = { "bad" },
          algorithm = "token_bucket",
          algorithm_config = { tokens_per_second = 10, burst = 20 },
        },
      },
    },
  }

  ctx.bundle = mock_bundle.new_bundle({
    bundle_version = 77,
    policies = { valid_policy_a, invalid_policy, valid_policy_b },
  })
  ctx.payload = mock_bundle.encode(ctx.bundle)
end)

runner:given("^the bundle expires in the past$", function(ctx)
  ctx.bundle = mock_bundle.new_bundle({
    bundle_version = 10,
    expires_at = "1970-01-01T00:00:00Z",
  })
  ctx.payload = mock_bundle.encode(ctx.bundle)
end)

runner:given("^a bundle with policy that has invalid fallback_limit$", function(ctx)
  local policy_invalid_fallback = {
    id = "policy-fb-invalid",
    spec = {
      selector = { pathPrefix = "/v1/", methods = { "GET" } },
      mode = "enforce",
      rules = {
        { name = "r1", limit_keys = { "jwt:org_id" }, algorithm = "token_bucket",
          algorithm_config = { tokens_per_second = 10, burst = 20 } },
      },
      fallback_limit = {
        name = "fb",
        limit_keys = { "jwt:org_id" },
        algorithm = "token_bucket",
        algorithm_config = { tokens_per_second = 1, burst = 2 },
      },
    },
  }
  policy_invalid_fallback.spec.fallback_limit.algorithm = nil
  policy_invalid_fallback.spec.fallback_limit.algorithm_config = nil
  ctx.bundle = mock_bundle.new_bundle({
    bundle_version = 1,
    policies = { policy_invalid_fallback },
  })
  ctx.payload = mock_bundle.encode(ctx.bundle)
end)

runner:given("^a bundle with policy that has valid fallback_limit$", function(ctx)
  local policy_valid_fallback = {
    id = "policy-fb-valid",
    spec = {
      selector = { pathPrefix = "/v1/", methods = { "GET" } },
      mode = "enforce",
      rules = {
        { name = "r1", limit_keys = { "jwt:org_id" }, algorithm = "token_bucket",
          algorithm_config = { tokens_per_second = 10, burst = 20 } },
      },
      fallback_limit = {
        name = "fallback_rule",
        limit_keys = { "jwt:org_id" },
        algorithm = "token_bucket",
        algorithm_config = { tokens_per_second = 5, burst = 10 },
      },
    },
  }
  ctx.bundle = mock_bundle.new_bundle({
    bundle_version = 1,
    policies = { policy_valid_fallback },
  })
  ctx.payload = mock_bundle.encode(ctx.bundle)
end)

runner:given("^a bundle with two policies with the same ID$", function(ctx)
  local first = {
    id = "dup-policy",
    spec = {
      selector = { pathPrefix = "/first/", methods = { "GET" } },
      mode = "enforce",
      rules = {
        { name = "r1", limit_keys = { "jwt:org_id" }, algorithm = "token_bucket",
          algorithm_config = { tokens_per_second = 10, burst = 20 } },
      },
    },
  }
  local second = {
    id = "dup-policy",
    spec = {
      selector = { pathPrefix = "/second/", methods = { "GET" } },
      mode = "enforce",
      rules = {
        { name = "r2", limit_keys = { "jwt:org_id" }, algorithm = "token_bucket",
          algorithm_config = { tokens_per_second = 5, burst = 10 } },
      },
    },
  }
  ctx.bundle = mock_bundle.new_bundle({
    bundle_version = 100,
    policies = { first, second },
  })
  ctx.payload = mock_bundle.encode(ctx.bundle)
end)

runner:given("^a bundle with active global shadow and kill switch override blocks$", function(ctx)
  ctx.bundle = mock_bundle.new_bundle({
    bundle_version = 303,
    global_shadow = {
      enabled = true,
      reason = "incident-global-shadow",
      expires_at = "2030-01-01T00:00:00Z",
    },
    kill_switch_override = {
      enabled = true,
      reason = "incident-ks-override",
      expires_at = "2030-01-01T00:00:00Z",
    },
  })
  ctx.payload = mock_bundle.encode(ctx.bundle)
end)

runner:given("^a bundle with invalid global shadow block$", function(ctx)
  ctx.bundle = mock_bundle.new_bundle({
    bundle_version = 304,
    global_shadow = {
      enabled = true,
      reason = "",
      expires_at = "2030-01-01T00:00:00Z",
    },
  })
  ctx.payload = mock_bundle.encode(ctx.bundle)
end)

runner:given("^a bundle with selector hosts set to empty array$", function(ctx)
  ctx.bundle = mock_bundle.new_bundle({
    bundle_version = 305,
  })
  ctx.bundle.policies[1].spec.selector.hosts = {}
  ctx.payload = mock_bundle.encode(ctx.bundle)
end)

runner:given("^a bundle with selector hosts containing invalid hostname$", function(ctx)
  ctx.bundle = mock_bundle.new_bundle({
    bundle_version = 306,
  })
  ctx.bundle.policies[1].spec.selector.hosts = { "https://api.example.com/v1" }
  ctx.payload = mock_bundle.encode(ctx.bundle)
end)

runner:given("^a bundle with selector hosts using uppercase hostname$", function(ctx)
  ctx.bundle = mock_bundle.new_bundle({
    bundle_version = 307,
  })
  ctx.bundle.policies[1].spec.selector.hosts = { "API.EXAMPLE.COM" }
  ctx.payload = mock_bundle.encode(ctx.bundle)
end)

runner:given("^the bundle uses version (%d+) for file loading$", function(ctx, version)
  ctx.bundle = mock_bundle.new_bundle({ bundle_version = tonumber(version) })
  ctx.payload = mock_bundle.encode(ctx.bundle)
  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  f:write(ctx.payload)
  f:close()
  ctx.file_path = tmp
end)

runner:given("^the hot reload file uses version (%d+)$", function(ctx, version)
  ctx.bundle = mock_bundle.new_bundle({ bundle_version = tonumber(version) })
  local payload = mock_bundle.encode(ctx.bundle)
  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  f:write(payload)
  f:close()
  ctx.file_path = tmp
end)

runner:when("^I load the signed bundle$", function(ctx)
  ctx.compiled, ctx.err = ctx.loader.load_from_string(ctx.signed_payload, ctx.signing_key, ctx.current_version)
end)

runner:when("^I load the unsigned bundle$", function(ctx)
  ctx.compiled, ctx.err = ctx.loader.load_from_string(ctx.payload, nil, ctx.current_version)
end)

runner:when("^I load the unsigned bundle with monotonic check$", function(ctx)
  ctx.compiled, ctx.err = ctx.loader.load_from_string(ctx.payload, nil, ctx.current_version)
end)

runner:when("^I load from file$", function(ctx)
  ctx.compiled, ctx.err = ctx.loader.load_from_file(ctx.file_path, nil, ctx.current_version)
  if ctx.file_path then
    pcall(os.remove, ctx.file_path)
    ctx.file_path = nil
  end
end)

runner:when("^I apply the compiled bundle$", function(ctx)
  ctx.apply_ok, ctx.apply_err = ctx.loader.apply(ctx.compiled)
end)

runner:when("^I initialize hot reload every (%d+) seconds$", function(ctx, interval)
  ctx.hot_reload_ok, ctx.hot_reload_err = ctx.loader.init_hot_reload(tonumber(interval), ctx.file_path, nil)
end)

runner:when("^I trigger the first hot reload callback$", function(ctx)
  ctx.env.timers[1].callback(false)
  if ctx.file_path then
    pcall(os.remove, ctx.file_path)
    ctx.file_path = nil
  end
end)

runner:when("^I validate the raw bundle table$", function(ctx)
  local parsed = _json_decode(ctx.payload)
  ctx.validation_errors = ctx.loader.validate_bundle(parsed)
end)

runner:when("^I validate the raw bundle using validate API$", function(ctx)
  local parsed = _json_decode(ctx.payload)
  ctx.validation_ok, ctx.validation_api_errors = ctx.loader.validate(parsed)
end)

runner:then_("^the load succeeds$", function(ctx)
  assert.is_table(ctx.compiled)
  assert.is_nil(ctx.err)
end)

runner:then_("^the load fails with error \"([^\"]+)\"$", function(ctx, expected_err)
  assert.is_nil(ctx.compiled)
  assert.equals(expected_err, ctx.err)
end)

runner:then_("^the compiled bundle has version (%d+) and non%-nil hash$", function(ctx, version)
  assert.equals(tonumber(version), ctx.compiled.version)
  assert.is_truthy(ctx.compiled.hash)
end)

runner:then_("^the compiled bundle has (%d+) valid policies$", function(ctx, policy_count)
  assert.equals(tonumber(policy_count), #ctx.compiled.policies)
end)

runner:then_("^the compiled bundle has policies_by_id keyed by policy ID$", function(ctx)
  assert.is_table(ctx.compiled.policies_by_id)
  local default_id = "policy-api-rate"
  assert.is_table(ctx.compiled.policies_by_id[default_id])
  assert.equals(default_id, ctx.compiled.policies_by_id[default_id].id)
  assert.is_table(ctx.compiled.policies_by_id[default_id].spec)
end)

runner:then_("^the compiled bundle includes runtime override blocks$", function(ctx)
  assert.is_table(ctx.compiled.global_shadow)
  assert.equals(true, ctx.compiled.global_shadow.enabled)
  assert.equals("incident-global-shadow", ctx.compiled.global_shadow.reason)
  assert.equals("2030-01-01T00:00:00Z", ctx.compiled.global_shadow.expires_at)

  assert.is_table(ctx.compiled.kill_switch_override)
  assert.equals(true, ctx.compiled.kill_switch_override.enabled)
  assert.equals("incident-ks-override", ctx.compiled.kill_switch_override.reason)
  assert.equals("2030-01-01T00:00:00Z", ctx.compiled.kill_switch_override.expires_at)
end)

runner:then_("^policies_by_id contains exactly one entry for that ID with the last policy spec$", function(ctx)
  local by_id = ctx.compiled.policies_by_id
  assert.is_table(by_id)
  assert.is_table(by_id["dup-policy"])
  assert.equals("dup-policy", by_id["dup-policy"].id)
  assert.equals("/second/", by_id["dup-policy"].spec.selector.pathPrefix)
end)

runner:then_("^one validation error is logged$", function(ctx)
  local found = 0
  for _, entry in ipairs(ctx.env.logs) do
    local line = table.concat(entry, "")
    if string.find(line, "validation_error=", 1, true) then
      found = found + 1
    end
  end
  assert.equals(1, found)
end)

runner:then_('^the load logs validation error containing "([^"]+)"$', function(ctx, expected)
  local found = false
  for _, entry in ipairs(ctx.env.logs) do
    local line = table.concat(entry, "")
    if string.find(line, expected, 1, true) then
      found = true
      break
    end
  end
  assert.is_true(found)
end)

runner:then_("^fallback_limit validation error is logged$", function(ctx)
  local found = false
  for _, entry in ipairs(ctx.env.logs) do
    local line = table.concat(entry, "")
    if string.find(line, "fallback_limit", 1, true)
        or string.find(line, "invalid_limit_keys", 1, true)
        or string.find(line, "invalid_algorithm_definition", 1, true)
        or (string.find(line, "validation_error=", 1, true) and string.find(line, "policy-fb-invalid", 1, true)) then
      found = true
      break
    end
  end
  assert.is_true(found, "expected fallback_limit validation error in validation logs")
end)

runner:then_("^the compiled bundle policy has fallback_limit in spec$", function(ctx)
  assert.is_table(ctx.compiled.policies_by_id)
  local policy = ctx.compiled.policies_by_id["policy-fb-valid"]
  assert.is_table(policy)
  assert.is_table(policy.spec.fallback_limit)
  assert.equals("fallback_rule", policy.spec.fallback_limit.name)
  assert.is_table(policy.spec.fallback_limit.limit_keys)
  assert.equals("token_bucket", policy.spec.fallback_limit.algorithm)
end)

runner:then_('^the compiled policy selector host at index (%d+) is "([^"]+)"$', function(ctx, index, expected_host)
  local i = tonumber(index)
  assert.is_table(ctx.compiled.policies)
  assert.is_table(ctx.compiled.policies[1])
  assert.is_table(ctx.compiled.policies[1].spec)
  assert.is_table(ctx.compiled.policies[1].spec.selector)
  assert.is_table(ctx.compiled.policies[1].spec.selector.hosts)
  assert.equals(expected_host, ctx.compiled.policies[1].spec.selector.hosts[i])
end)

runner:then_("^the active bundle is version (%d+)$", function(ctx, version)
  local current = ctx.loader.get_current()
  assert.is_table(current)
  assert.equals(tonumber(version), current.version)
end)

runner:then_("^health state stores version (%d+) and hash$", function(ctx, version)
  local state = ctx.health.get_bundle_state()
  assert.equals(tonumber(version), state.version)
  assert.is_truthy(state.hash)
  assert.is_truthy(state.loaded_at)
end)

runner:then_("^hot reload initialization succeeds$", function(ctx)
  assert.is_true(ctx.hot_reload_ok)
  assert.is_nil(ctx.hot_reload_err)
  assert.equals(1, #ctx.env.timers)
end)

runner:then_("^the hot reload applies version (%d+)$", function(ctx, version)
  local current = ctx.loader.get_current()
  assert.equals(tonumber(version), current.version)
end)

runner:then_("^validation has no top%-level errors$", function(ctx)
  assert.equals(0, #ctx.validation_errors)
end)

runner:then_("^validation API reports success$", function(ctx)
  assert.is_true(ctx.validation_ok)
  assert.is_nil(ctx.validation_api_errors)
end)

runner:feature_file_relative("features/bundle_loader.feature")
