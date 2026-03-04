package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local route_index = require("fairvisor.route_index")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _new_policy(id, selector, nested)
  if nested then
    return { id = id, spec = { selector = selector } }
  end
  return { id = id, selector = selector }
end

runner:given("^an empty policy set$", function(ctx)
  ctx.policies = {}
end)

runner:given('^a single policy "([^"]+)" with pathExact "([^"]+)"$', function(ctx, id, path_exact)
  ctx.policies = { _new_policy(id, { pathExact = path_exact }, true) }
end)

runner:given('^a single policy "([^"]+)" with pathPrefix "([^"]+)"$', function(ctx, id, path_prefix)
  ctx.policies = { _new_policy(id, { pathPrefix = path_prefix }, true) }
end)

runner:given('^a single policy "([^"]+)" with both pathExact "([^"]+)" and pathPrefix "([^"]+)"$',
  function(ctx, id, path_exact, path_prefix)
    ctx.policies = { _new_policy(id, { pathExact = path_exact, pathPrefix = path_prefix }, true) }
  end
)

runner:given('^a single policy "([^"]+)" with pathExact "([^"]+)" and methods "([^"]+)"$', function(ctx, id, path_exact, methods_csv)
  local methods = {}
  for method in string.gmatch(methods_csv, "[^, ]+") do
    methods[#methods + 1] = method
  end
  ctx.policies = { _new_policy(id, { pathExact = path_exact, methods = methods }, false) }
end)

runner:given('^a policy "([^"]+)" with pathExact "([^"]+)" and a policy "([^"]+)" with pathPrefix "([^"]+)"$',
  function(ctx, exact_id, exact_path, prefix_id, prefix_path)
    ctx.policies = {
      _new_policy(prefix_id, { pathPrefix = prefix_path }, true),
      _new_policy(exact_id, { pathExact = exact_path }, true),
    }
  end
)

runner:given('^a policy "([^"]+)" with pathPrefix "([^"]+)" and a policy "([^"]+)" with pathPrefix "([^"]+)"$',
  function(ctx, id_a, prefix_a, id_b, prefix_b)
    ctx.policies = {
      _new_policy(id_a, { pathPrefix = prefix_a }, true),
      _new_policy(id_b, { pathPrefix = prefix_b }, false),
    }
  end
)

runner:given('^a single policy "([^"]+)" with pathExact "([^"]+)" and no methods$', function(ctx, id, path_exact)
  ctx.policies = { _new_policy(id, { pathExact = path_exact }, true) }
end)

runner:given("^a policy missing both path selectors$", function(ctx)
  ctx.policies = {
    _new_policy("bad-policy", { methods = { "GET" } }, true),
  }
end)

runner:given("^a host%-scoped and a host%-agnostic policy for /v1/$", function(ctx)
  ctx.policies = {
    _new_policy("policy-host", {
      hosts = { "api.example.com" },
      pathPrefix = "/v1/",
      methods = { "GET" },
    }, true),
    _new_policy("policy-global", {
      pathPrefix = "/v1/",
      methods = { "GET" },
    }, true),
  }
end)

runner:given("^a host policy with uppercase host and port$", function(ctx)
  ctx.policies = {
    _new_policy("policy-host", {
      hosts = { "API.EXAMPLE.COM:443" },
      pathPrefix = "/v1/",
      methods = { "GET" },
    }, true),
  }
end)

runner:given("^fifty policies with two exact and two prefix routes each$", function(ctx)
  local policies = {}
  for i = 1, 50 do
    local id = "policy-" .. i
    local base = "/v" .. ((i % 5) + 1) .. "/svc" .. i
    policies[#policies + 1] = _new_policy(id .. "-a", { pathExact = base .. "/a" }, true)
    policies[#policies + 1] = _new_policy(id .. "-b", { pathExact = base .. "/b" }, true)
    policies[#policies + 1] = _new_policy(id .. "-c", { pathPrefix = base .. "/c" }, false)
    policies[#policies + 1] = _new_policy(id .. "-d", { pathPrefix = base .. "/d/" }, true)
  end
  ctx.policies = policies
end)

runner:when("^I build the route index$", function(ctx)
  local started_at = os.clock()
  ctx.index, ctx.err = route_index.build(ctx.policies)
  ctx.build_seconds = os.clock() - started_at
end)

runner:when('^I match method "([^"]+)" and path "([^"]*)"$', function(ctx, method, path)
  ctx.matches = ctx.index:match(method, path)
end)

runner:when('^I match host "([^"]*)" method "([^"]+)" and path "([^"]*)"$', function(ctx, host, method, path)
  ctx.matches = ctx.index:match(host, method, path)
end)

runner:when("^I run ten thousand lookups for GET /v1/svc1/a$", function(ctx)
  local started_at = os.clock()
  local count = 10000
  local last_matches
  for _ = 1, count do
    last_matches = ctx.index:match("GET", "/v1/svc1/a")
  end
  local elapsed = os.clock() - started_at
  ctx.lookup_average_seconds = elapsed / count
  ctx.matches = last_matches
end)

runner:then_("^build succeeds$", function(ctx)
  assert.is_table(ctx.index)
  assert.is_nil(ctx.err)
end)

runner:then_('^the result contains only policy "([^"]+)"$', function(ctx, id)
  assert.same({ id }, ctx.matches)
end)

runner:then_('^the result contains both policies "([^"]+)" and "([^"]+)"$', function(ctx, id_a, id_b)
  assert.equals(2, #ctx.matches)
  local set = {}
  for i = 1, #ctx.matches do
    set[ctx.matches[i]] = true
  end
  assert.is_true(set[id_a])
  assert.is_true(set[id_b])
end)

runner:then_('^the result contains policy "([^"]+)"$', function(ctx, id)
  local found = false
  for i = 1, #ctx.matches do
    if ctx.matches[i] == id then
      found = true
      break
    end
  end
  assert.is_true(found)
end)

runner:then_("^the result is empty$", function(ctx)
  assert.same({}, ctx.matches)
end)

runner:then_("^build time benchmark is recorded$", function(ctx)
  assert.is_true(type(ctx.build_seconds) == "number")
  assert.is_true(ctx.build_seconds >= 0)
end)

runner:then_("^lookup time benchmark is recorded$", function(ctx)
  assert.is_true(type(ctx.lookup_average_seconds) == "number")
  assert.is_true(ctx.lookup_average_seconds >= 0)
end)

runner:feature_file_relative("features/route_index.feature")
