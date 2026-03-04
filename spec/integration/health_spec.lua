package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local health = require("fairvisor.health")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _contains(haystack, needle)
  return string.find(haystack, needle, 1, true) ~= nil
end

runner:given("^a fresh health and metrics registry$", function(ctx)
  ctx.instance = health.new()
end)

runner:given("^a health instance configured with edge version v9%.9%.9$", function(ctx)
  ctx.instance = health.new({ edge_version = "v9.9.9" })
end)

runner:given("^the bundle is loaded as version v1$", function(ctx)
  ctx.instance:set_bundle_state("v1", "hash-v1", 1708000000)
end)

runner:given("^the bundle is reloaded as version v2$", function(ctx)
  ctx.instance:set_bundle_state("v2", "hash-v2", 1708100000)
end)

runner:given("^standard metrics are registered$", function(ctx)
  local ok, err = ctx.instance:register("test_decisions_total", "counter", "Total decisions")
  assert.is_true(ok)
  assert.is_nil(err)

  ok, err = ctx.instance:register("test_circuit_state", "gauge", "Circuit breaker state")
  assert.is_true(ok)
  assert.is_nil(err)
end)

runner:given("^decision and breaker metrics are emitted$", function(ctx)
  ctx.instance:inc("test_decisions_total", { route = "/v1/data", action = "allow" }, 2)
  ctx.instance:inc("test_decisions_total", { route = "/v1/data", action = "reject" }, 1)
  ctx.instance:set("test_circuit_state", { limit_key = "org-1" }, 1)
end)

runner:when("^readiness is checked$", function(ctx)
  ctx.ready, ctx.ready_err = ctx.instance:readyz()
end)

runner:when("^liveness is checked$", function(ctx)
  ctx.livez = ctx.instance:livez()
end)

runner:when("^metrics are rendered$", function(ctx)
  ctx.rendered = ctx.instance:render()
end)

runner:then_("^readiness returns ready for v2 metadata$", function(ctx)
  assert.is_nil(ctx.ready_err)
  assert.equals("ready", ctx.ready.status)
  assert.equals("v2", ctx.ready.policy_version)
  assert.equals("hash-v2", ctx.ready.policy_hash)
  assert.equals(1708100000, ctx.ready.last_config_update)
end)

runner:then_("^render output includes deterministic series and metadata lines$", function(ctx)
  assert.is_true(_contains(ctx.rendered, "# HELP test_circuit_state Circuit breaker state"))
  assert.is_true(_contains(ctx.rendered, "# TYPE test_circuit_state gauge"))
  assert.is_true(_contains(ctx.rendered, "# HELP test_decisions_total Total decisions"))
  assert.is_true(_contains(ctx.rendered, "# TYPE test_decisions_total counter"))
  assert.is_true(_contains(ctx.rendered, 'test_decisions_total{action="allow",route="/v1/data"} 2'))
  assert.is_true(_contains(ctx.rendered, 'test_decisions_total{action="reject",route="/v1/data"} 1'))
  assert.is_true(_contains(ctx.rendered, 'test_circuit_state{limit_key="org-1"} 1'))
end)

runner:then_("^liveness reports the configured edge version$", function(ctx)
  assert.same({ status = "healthy", version = "v9.9.9" }, ctx.livez)
end)

runner:feature_file_relative("features/health.feature")
