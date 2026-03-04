package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

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

runner:given("^the integration environment is reset$", function(ctx)
  ctx.env = mock_ngx.setup_ngx()
  ctx.loader, ctx.health = _reload_modules()
end)

runner:given("^a valid bundle payload at version (%d+)$", function(ctx, version)
  local bundle = mock_bundle.new_bundle({ bundle_version = tonumber(version) })
  ctx.payload = mock_bundle.encode(bundle)
end)

runner:given("^a file bundle payload at version (%d+)$", function(ctx, version)
  local bundle = mock_bundle.new_bundle({ bundle_version = tonumber(version) })
  local payload = mock_bundle.encode(bundle)
  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  f:write(payload)
  f:close()
  ctx.file_path = tmp
end)

runner:when("^I compile the payload with current version nil$", function(ctx)
  ctx.compiled, ctx.err = ctx.loader.load_from_string(ctx.payload, nil, nil)
end)

runner:when("^I apply the compiled payload$", function(ctx)
  ctx.apply_ok, ctx.apply_err = ctx.loader.apply(ctx.compiled)
end)

runner:when("^I initialize file hot reload every (%d+) seconds$", function(ctx, interval)
  ctx.hot_reload_ok, ctx.hot_reload_err = ctx.loader.init_hot_reload(tonumber(interval), ctx.file_path, nil)
end)

runner:when("^I execute the first timer callback$", function(ctx)
  ctx.env.timers[1].callback(false)
  if ctx.file_path then
    pcall(os.remove, ctx.file_path)
    ctx.file_path = nil
  end
end)

runner:then_("^the compiled payload is ready$", function(ctx)
  assert.is_table(ctx.compiled)
  assert.is_nil(ctx.err)
  assert.is_table(ctx.compiled.route_index)
end)

runner:then_("^the bundle is active at version (%d+)$", function(ctx, version)
  local current = ctx.loader.get_current()
  assert.equals(tonumber(version), current.version)
end)

runner:then_("^ready state is updated with version (%d+)$", function(ctx, version)
  local state = ctx.health.get_bundle_state()
  assert.equals(tonumber(version), state.version)
  assert.is_truthy(state.hash)
  assert.is_truthy(state.loaded_at)
end)

runner:then_("^the timer is registered once$", function(ctx)
  assert.is_true(ctx.hot_reload_ok)
  assert.is_nil(ctx.hot_reload_err)
  assert.equals(1, #ctx.env.timers)
end)

runner:feature_file_relative("features/bundle_loader.feature")
