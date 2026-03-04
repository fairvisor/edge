package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local health = require("fairvisor.health")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _contains(haystack, needle)
  return string.find(haystack, needle, 1, true) ~= nil
end

runner:given("^a new health instance$", function(ctx)
  ctx.instance = health.new()
end)

runner:given("^a new health instance with no bundle loaded$", function(ctx)
  ctx.instance = health.new()
end)

runner:given('^set_bundle_state%("([^"]+)", "([^"]+)", (%d+)%) is called$', function(ctx, version, hash, timestamp)
  ctx.instance:set_bundle_state(version, hash, tonumber(timestamp))
end)

runner:given('^a registered counter "([^"]+)"$', function(ctx, name)
  ctx.metric_name = name
  local ok, err = ctx.instance:register(name, "counter", "Total decisions")
  assert.is_true(ok)
  assert.is_nil(err)
end)

runner:given('^a registered gauge "([^"]+)"$', function(ctx, name)
  ctx.metric_name = name
  local ok, err = ctx.instance:register(name, "gauge", "Circuit breaker state")
  assert.is_true(ok)
  assert.is_nil(err)
end)

runner:given('^a registered counter "([^"]+)" with help "([^"]+)"$', function(ctx, name, help_text)
  ctx.metric_name = name
  local ok, err = ctx.instance:register(name, "counter", help_text)
  assert.is_true(ok)
  assert.is_nil(err)
end)

runner:given('^a counter with labels { route = "([^"]+)", action = "([^"]+)" }$', function(ctx, route, action)
  ctx.metric_name = "test_decisions_total"
  local ok, err = ctx.instance:register(ctx.metric_name, "counter", "Total decisions")
  assert.is_true(ok)
  assert.is_nil(err)
  ctx.instance:inc(ctx.metric_name, { route = route, action = action }, 1)
end)

runner:given("^a counter incremented with nil labels$", function(ctx)
  ctx.metric_name = "test_decisions_total"
  local ok, err = ctx.instance:register(ctx.metric_name, "counter", "Total decisions")
  assert.is_true(ok)
  assert.is_nil(err)
  ctx.instance:inc(ctx.metric_name, nil, 1)
end)

runner:given("^a counter with label value containing quote and backslash$", function(ctx)
  ctx.metric_name = "test_decisions_total"
  local ok, err = ctx.instance:register(ctx.metric_name, "counter", "Total decisions")
  assert.is_true(ok)
  assert.is_nil(err)
  ctx.instance:inc(ctx.metric_name, { special = 'say "hi" \\ path' }, 1)
end)

runner:given('^"([^"]+)" is already registered$', function(ctx, name)
  ctx.metric_name = name
  local ok, err = ctx.instance:register(name, "counter", "Total decisions")
  assert.is_true(ok)
  assert.is_nil(err)
end)

runner:given("^no metrics registered$", function(ctx)
  ctx.instance = health.new()
end)

runner:given("^a health instance with initial bundle state v1$", function(ctx)
  ctx.instance = health.new()
  ctx.instance:set_bundle_state("v1", "abc123", 1708000000)
end)

runner:given("^the default health instance is used$", function(ctx)
  -- Module-level API uses internal default instance; no ctx.instance for this scenario.
end)

runner:when('^module%-level set_bundle_state%("([^"]+)", "([^"]+)", (%d+)%) is called$', function(ctx, version, hash, timestamp)
  health.set_bundle_state(version, hash, tonumber(timestamp))
end)

runner:when("^module%-level get_bundle_state is called$", function(ctx)
  ctx.bundle_state = health.get_bundle_state()
end)

runner:when("^livez is called$", function(ctx)
  ctx.livez = ctx.instance:livez()
end)

runner:when("^readyz is called$", function(ctx)
  ctx.ready, ctx.ready_err = ctx.instance:readyz()
end)

runner:when("^inc is called with labels { action = \"allow\" } and value 1$", function(ctx)
  ctx.instance:inc(ctx.metric_name, { action = "allow" }, 1)
end)

runner:when("^inc is called again with same labels$", function(ctx)
  ctx.instance:inc(ctx.metric_name, { action = "allow" })
end)

runner:when("^set is called with labels { limit_key = \"org%-1\" } and value 1$", function(ctx)
  ctx.instance:set(ctx.metric_name, { limit_key = "org-1" }, 1)
end)

runner:when("^render is called$", function(ctx)
  ctx.rendered = ctx.instance:render()
end)

runner:when('^register is called again with the same name$', function(ctx)
  ctx.dup_ok, ctx.dup_err = ctx.instance:register(ctx.metric_name, "counter", "Duplicate")
end)

runner:when('^inc is called for "([^"]+)"$', function(ctx, name)
  ctx.instance:inc(name, { action = "allow" }, 1)
end)

runner:when('^set_bundle_state%("([^"]+)", "([^"]+)", (%d+)%) is called$', function(ctx, version, hash, timestamp)
  ctx.instance:set_bundle_state(version, hash, tonumber(timestamp))
end)

runner:then_("^result is { status = \"healthy\", version = \"0%.1%.0\" }$", function(ctx)
  assert.same({ status = "healthy", version = "0.1.0" }, ctx.livez)
end)

runner:then_("^first return is nil$", function(ctx)
  assert.is_nil(ctx.ready)
end)

runner:then_("^second return is { status = \"not_ready\", reason = \"no_policy_loaded\" }$", function(ctx)
  assert.same({ status = "not_ready", reason = "no_policy_loaded" }, ctx.ready_err)
end)

runner:then_("^result is { status = \"ready\", policy_version = \"v42\", policy_hash = \"abc123\", last_config_update = 1708000000 }$",
  function(ctx)
    assert.same({
      status = "ready",
      policy_version = "v42",
      policy_hash = "abc123",
      last_config_update = 1708000000,
    }, ctx.ready)
  end
)

runner:then_('^render includes \'test_decisions_total{action="allow"} 2\'$', function(ctx)
  assert.is_true(_contains(ctx.rendered, 'test_decisions_total{action="allow"} 2'))
end)

runner:then_('^render includes \'([^\']+)\'$', function(ctx, expected_line)
  assert.is_true(_contains(ctx.rendered, expected_line))
end)

runner:then_('^render includes \'test_circuit_state{limit_key="org%-1"} 1\'$', function(ctx)
  assert.is_true(_contains(ctx.rendered, 'test_circuit_state{limit_key="org-1"} 1'))
end)

runner:then_('^output includes \'# HELP test_decisions_total Total decisions\'$', function(ctx)
  assert.is_true(_contains(ctx.rendered, "# HELP test_decisions_total Total decisions"))
end)

runner:then_('^output includes \'# TYPE test_decisions_total counter\'$', function(ctx)
  assert.is_true(_contains(ctx.rendered, "# TYPE test_decisions_total counter"))
end)

runner:then_('^label string is \'{action="reject",route="/v1"}\'$', function(ctx)
  assert.is_true(_contains(ctx.rendered, 'test_decisions_total{action="reject",route="/v1"} 1'))
end)

runner:then_('^metric line has no braces: \'test_decisions_total 1\'$', function(ctx)
  assert.is_true(_contains(ctx.rendered, "test_decisions_total 1"))
  assert.is_false(_contains(ctx.rendered, "test_decisions_total{} 1"))
end)

runner:then_("^quotes are escaped as .+$", function(ctx)
  assert.is_true(_contains(ctx.rendered, 'special="say \\\"hi\\\" \\\\ path"'))
end)

runner:then_('^it returns nil, "metric already registered"$', function(ctx)
  assert.is_nil(ctx.dup_ok)
  assert.equals("metric already registered", ctx.dup_err)
end)

runner:then_("^policy_version is \"v2\" and policy_hash is \"def456\"$", function(ctx)
  assert.equals("v2", ctx.ready.policy_version)
  assert.equals("def456", ctx.ready.policy_hash)
  assert.equals(1708100000, ctx.ready.last_config_update)
end)

runner:then_('^bundle state has version "([^"]+)", hash "([^"]+)", loaded_at (%d+)$', function(ctx, version, hash, loaded_at)
  assert.is_table(ctx.bundle_state)
  assert.equals(version, ctx.bundle_state.version)
  assert.equals(hash, ctx.bundle_state.hash)
  assert.equals(tonumber(loaded_at), ctx.bundle_state.loaded_at)
end)

runner:feature_file_relative("features/health.feature")
