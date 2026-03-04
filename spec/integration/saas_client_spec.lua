package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local saas_client = require("fairvisor.saas_client")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")
local mock_http = require("helpers.mock_http")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _bundle_loader(initial)
  local state = {
    current = initial,
    applied = 0,
    loaded = 0,
  }

  local loader = {}

  function loader:get_current()
    return state.current
  end

  function loader:load_from_string(raw, signing_key, prev_version)
    state.loaded = state.loaded + 1
    if raw and raw.reject then
      return nil, "invalid bundle"
    end

    return {
      version = raw and raw.version or "v-next",
      hash = raw and raw.hash or "hash-next",
    }
  end

  function loader:apply(compiled)
    state.applied = state.applied + 1
    state.current = compiled
  end

  return loader, state
end

local function _health()
  local state = { set_calls = {}, inc_calls = {} }
  local health = {}

  function health:set(name, tags, value)
    state.set_calls[#state.set_calls + 1] = { name = name, tags = tags, value = value }
  end

  function health:inc(name, tags, value)
    state.inc_calls[#state.inc_calls + 1] = { name = name, tags = tags, value = value }
  end

  return health, state
end

runner:given("^the integration nginx mock is reset$", function(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.time = env.time
  ctx.timers = {}

  ngx.timer = {
    every = function(interval, fn)
      ctx.timers[#ctx.timers + 1] = { interval = interval, fn = fn }
      return true
    end,
  }
end)

runner:given("^a SaaS client integration fixture$", function(ctx)
  ctx.config = {
    edge_id = "edge-int-1",
    edge_token = "token-int",
    saas_url = "https://saas.integration",
    signing_key = "sig",
    heartbeat_interval = 5,
    event_flush_interval = 60,
    config_poll_interval = 30,
    max_batch_size = 100,
    max_buffer_size = 100,
  }

  local loader, loader_state = _bundle_loader({ version = "v1", hash = "h1" })
  local health, health_state = _health()
  local http_env = mock_http.new()

  ctx.loader_state = loader_state
  ctx.health_state = health_state
  ctx.http = http_env

  ctx.deps = {
    bundle_loader = loader,
    health = health,
    http_client = http_env.client,
  }
end)

runner:given("^registration and heartbeat are accepted$", function(ctx)
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/register", { status = 200 })
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/heartbeat", {
    status = 200,
    body = { config_update_available = false, server_time = ctx.time.now() },
  })
end)

runner:given("^heartbeat indicates a config update and config endpoint returns new bundle$", function(ctx)
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/register", { status = 200 })
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/heartbeat", {
    status = 200,
    body = { config_update_available = true, server_time = ctx.time.now() },
  })
  ctx.http.queue_response("GET", ctx.config.saas_url .. "/api/v1/edge/config", {
    status = 200,
    body = { version = "v2", hash = "h2" },
  })
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/config/ack", { status = 200 })
end)

runner:given("^registration succeeds and events endpoint accepts a batch$", function(ctx)
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/register", { status = 200 })
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/events", { status = 200 })
end)

runner:given("^registration succeeds and heartbeats fail (%d+) times$", function(ctx, count)
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/register", { status = 200 })
  for _ = 1, tonumber(count) do
    ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/heartbeat", { status = 500 })
  end
end)

runner:when("^I initialize the SaaS client$", function(ctx)
  ctx.ok, ctx.err = saas_client.init(ctx.config, ctx.deps)
end)

runner:when("^I run one heartbeat tick$", function(ctx)
  ctx.timers[1].fn(false)
end)

runner:when("^I run (%d+) heartbeat ticks$", function(ctx, count)
  for _ = 1, tonumber(count) do
    ctx.timers[1].fn(false)
    ctx.time.advance_time(70)
  end
end)

runner:when("^I queue one event and run one flush tick$", function(ctx)
  saas_client.queue_event({ kind = "decision", id = "e-1" })
  if ctx.timers and ctx.timers[2] then
    ctx.timers[2].fn(false)
  end
end)

runner:when("^I queue one event and trigger flush_events$", function(ctx)
  saas_client.queue_event({ kind = "decision", id = "e-1" })
  ctx.flushed = saas_client.flush_events()
end)

runner:then_("^initialization succeeds in integration$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
end)

runner:then_("^CT%-001 heartbeat contract payload contains edge identity and policy hash$", function(ctx)
  local found = false
  for _, request in ipairs(ctx.http.requests) do
    if request.url == ctx.config.saas_url .. "/api/v1/edge/heartbeat" then
      found = true
      assert.equals("edge-int-1", request.body.edge_id)
      assert.equals("h1", request.body.policy_hash)
      assert.is_not_nil(request.body.timestamp)
    end
  end

  assert.is_true(found)
end)

runner:then_("^CT%-002 config contract applies bundle and sends ack$", function(ctx)
  assert.equals(1, ctx.loader_state.loaded)
  assert.equals(1, ctx.loader_state.applied)

  local ack_found = false
  for _, request in ipairs(ctx.http.requests) do
    if request.url == ctx.config.saas_url .. "/api/v1/edge/config/ack" then
      ack_found = true
      assert.equals("applied", request.body.status)
      assert.equals("v2", request.body.version)
      assert.equals("h2", request.body.hash)
    end
  end

  assert.is_true(ack_found)
end)

runner:then_("^CT%-003 events contract sends idempotent batch delivery$", function(ctx)
  assert.equals(1, ctx.flushed)

  local found = false
  for _, request in ipairs(ctx.http.requests) do
    if request.url == ctx.config.saas_url .. "/api/v1/edge/events" then
      found = true
      assert.equals("edge-int-1", request.body.edge_id)
      assert.equals(1, #request.body.events)
      assert.is_not_nil(request.headers["Idempotency-Key"])
    end
  end

  assert.is_true(found)
end)

runner:then_("^CT%-004 circuit opens and reachability metric is updated$", function(ctx)
  assert.equals("disconnected", saas_client.get_state())

  local found_down = false
  for _, call in ipairs(ctx.health_state.set_calls) do
    if call.name == "fairvisor_saas_reachable" and call.value == 0 then
      found_down = true
    end
  end

  assert.is_true(found_down)
end)

runner:feature_file_relative("features/saas_client.feature")
