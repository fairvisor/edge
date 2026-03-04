package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local saas_client = require("fairvisor.saas_client")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")
local mock_http = require("helpers.mock_http")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _new_bundle_loader()
  local state = {
    current = nil,
    load_calls = {},
    apply_calls = {},
  }

  local loader = {}

  function loader:get_current()
    return state.current
  end

  function loader:load_from_string(raw, signing_key, prev_version)
    state.load_calls[#state.load_calls + 1] = {
      raw = raw,
      signing_key = signing_key,
      prev_version = prev_version,
    }

    if type(raw) == "table" and raw.reject then
      return nil, "invalid bundle"
    end

    local compiled = {
      version = type(raw) == "table" and raw.version or "v-next",
      hash = type(raw) == "table" and raw.hash or "hash-next",
    }
    return compiled
  end

  function loader:apply(compiled)
    state.apply_calls[#state.apply_calls + 1] = compiled
    state.current = compiled
    return true
  end

  return loader, state
end

local function _new_health()
  local state = { sets = {}, incs = {} }
  local health = {}

  function health:set(name, tags, value)
    state.sets[#state.sets + 1] = { name = name, tags = tags, value = value }
    return true
  end

  function health:inc(name, tags, value)
    state.incs[#state.incs + 1] = { name = name, tags = tags, value = value }
    return true
  end

  return health, state
end

runner:given("^the nginx mock environment with timer capture is reset$", function(ctx)
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

runner:given("^a default SaaS client config$", function(ctx)
  ctx.config = {
    edge_id = "edge-test-1",
    edge_token = "token-1",
    saas_url = "https://saas.example",
    signing_key = "pub-key",
    heartbeat_interval = 5,
    event_flush_interval = 60,
    config_poll_interval = 30,
    max_batch_size = 2,
    max_buffer_size = 3,
  }
end)

runner:given("^config poll interval is (%d+) seconds$", function(ctx, seconds)
  ctx.config.config_poll_interval = tonumber(seconds)
end)

runner:given("^bundle_loader starts with hash \"([^\"]+)\" and version \"([^\"]+)\"$", function(ctx, hash, version)
  local bundle_loader, bundle_state = _new_bundle_loader()
  bundle_state.current = { hash = hash, version = version }
  ctx.bundle_loader = bundle_loader
  ctx.bundle_state = bundle_state
end)

runner:given("^default bundle_loader and health dependencies$", function(ctx)
  if not ctx.bundle_loader then
    ctx.bundle_loader, ctx.bundle_state = _new_bundle_loader()
  end

  ctx.health, ctx.health_state = _new_health()
  local http_env = mock_http.new()
  ctx.http = http_env

  ctx.deps = {
    bundle_loader = ctx.bundle_loader,
    health = ctx.health,
    http_client = http_env.client,
  }
end)

runner:given("^registration succeeds$", function(ctx)
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/register", { status = 200 })
end)

runner:given("^registration fails with transport error$", function(ctx)
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/register", nil, "dial timeout")
end)

runner:given("^heartbeat succeeds with config update available$", function(ctx)
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/heartbeat", {
    status = 200,
    body = {
      config_update_available = true,
      server_time = ctx.time.now(),
    },
  })
end)

runner:given("^heartbeat succeeds with no update and server time skew of (%d+) seconds$", function(ctx, skew)
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/heartbeat", {
    status = 200,
    body = {
      config_update_available = false,
      server_time = ctx.time.now() - tonumber(skew),
    },
  })
end)

runner:given("^heartbeat returns retriable failure (%d+) times$", function(ctx, count)
  local n = tonumber(count)
  for _ = 1, n do
    ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/heartbeat", { status = 500 })
  end
end)

runner:given("^heartbeat succeeds (%d+) times$", function(ctx, count)
  local n = tonumber(count)
  for _ = 1, n do
    ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/heartbeat", {
      status = 200,
      body = { config_update_available = false, server_time = ctx.time.now() },
    })
  end
end)

runner:given("^heartbeat responds with non%-retriable status (%d+)$", function(ctx, status)
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/heartbeat", { status = tonumber(status) })
end)

runner:given("^config pull returns 200 with bundle hash \"([^\"]+)\" and version \"([^\"]+)\"$", function(ctx, hash, version)
  ctx.http.queue_response("GET", ctx.config.saas_url .. "/api/v1/edge/config", {
    status = 200,
    body = { hash = hash, version = version },
  })
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/config/ack", { status = 200 })
end)

runner:given("^config pull returns 304$", function(ctx)
  ctx.http.queue_response("GET", ctx.config.saas_url .. "/api/v1/edge/config", { status = 304 })
end)

runner:given("^config pull returns 304 (%d+) times$", function(ctx, count)
  for _ = 1, tonumber(count) do
    ctx.http.queue_response("GET", ctx.config.saas_url .. "/api/v1/edge/config", { status = 304 })
  end
end)

runner:given("^events endpoint accepts one batch$", function(ctx)
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/events", { status = 200 })
end)

runner:given("^events endpoint fails with status (%d+)$", function(ctx, status)
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/events", { status = tonumber(status) })
end)

runner:given("^the client is initialized$", function(ctx)
  ctx.ok, ctx.err = saas_client.init(ctx.config, ctx.deps)
end)

runner:given("^I queue events with ids: ([%d, ]+)$", function(ctx, ids)
  for id in string.gmatch(ids, "%d+") do
    saas_client.queue_event({ id = tonumber(id) })
  end
end)

runner:given("^time advances by ([%d%.]+) seconds$", function(ctx, seconds)
  ctx.time.advance_time(tonumber(seconds))
end)

runner:when("^the heartbeat timer callback runs$", function(ctx)
  ctx.timers[1].fn(false)
end)

runner:when("^the heartbeat timer callback runs (%d+) times$", function(ctx, count)
  for _ = 1, tonumber(count) do
    ctx.timers[1].fn(false)
    ctx.time.advance_time(70)
  end
end)

runner:when("^the event flush timer callback runs$", function(ctx)
  ctx.timers[2].fn(false)
end)

runner:when("^I force flush events$", function(ctx)
  ctx.flushed = saas_client.flush_events()
end)

runner:when("^I trigger pull_config manually$", function(ctx)
  ctx.pull_ok, ctx.pull_err = saas_client.pull_config()
end)

runner:then_("^initialization succeeds$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
end)

runner:then_("^initialization fails$", function(ctx)
  assert.is_nil(ctx.ok)
  assert.is_truthy(ctx.err)
end)

runner:then_("^queue_event returns not initialized error$", function(_)
  local ok, err = saas_client.queue_event({ id = 1 })
  assert.is_nil(ok)
  assert.equals("saas_client is not initialized", err)
end)

runner:then_("^two recurring timers are registered at heartbeat (%d+) and event flush (%d+)$",
  function(ctx, heartbeat, flush)
    assert.equals(2, #ctx.timers)
    assert.equals(tonumber(heartbeat), ctx.timers[1].interval)
    assert.equals(tonumber(flush), ctx.timers[2].interval)
  end
)

runner:then_("^the register endpoint is called once with bearer auth$", function(ctx)
  local count = 0
  for _, request in ipairs(ctx.http.requests) do
    if request.method == "POST" and request.url == ctx.config.saas_url .. "/api/v1/edge/register" then
      count = count + 1
      assert.equals("Bearer " .. ctx.config.edge_token, request.headers.Authorization)
    end
  end
  assert.equals(1, count)
end)

runner:then_("^a conditional config pull includes If%-None%-Match with current hash$", function(ctx)
  local found = false
  for _, request in ipairs(ctx.http.requests) do
    if request.method == "GET" and request.url == ctx.config.saas_url .. "/api/v1/edge/config" then
      found = true
      assert.equals("base-hash", request.headers["If-None-Match"])
      break
    end
  end
  assert.is_true(found)
end)

runner:then_("^the bundle is applied and acked as applied$", function(ctx)
  assert.equals(1, #ctx.bundle_state.apply_calls)

  local ack_found = false
  for _, request in ipairs(ctx.http.requests) do
    if request.method == "POST" and request.url == ctx.config.saas_url .. "/api/v1/edge/config/ack" then
      ack_found = true
      assert.equals("applied", request.body.status)
      assert.equals("hash-new", request.body.hash)
    end
  end

  assert.is_true(ack_found)
end)

runner:then_("^manual pull succeeds with no bundle load$", function(ctx)
  assert.is_true(ctx.pull_ok)
  assert.is_nil(ctx.pull_err)
  assert.equals(0, #ctx.bundle_state.load_calls)
end)

runner:then_("^the circuit state becomes disconnected$", function()
  assert.equals("disconnected", saas_client.get_state())
end)

runner:then_("^the circuit state becomes half_open$", function()
  assert.equals("half_open", saas_client.get_state())
end)

runner:then_("^the circuit state becomes connected$", function()
  assert.equals("connected", saas_client.get_state())
end)

runner:then_("^reachable metric is set to (%d+)$", function(ctx, value)
  local seen = false
  for _, metric in ipairs(ctx.health_state.sets) do
    if metric.name == "fairvisor_saas_reachable" and metric.value == tonumber(value) then
      seen = true
    end
  end
  assert.is_true(seen)
end)

runner:then_("^the event batch uses an Idempotency%-Key header$", function(ctx)
  local found = false
  for _, request in ipairs(ctx.http.requests) do
    if request.url == ctx.config.saas_url .. "/api/v1/edge/events" then
      found = true
      local key = request.headers["Idempotency-Key"]
      assert.is_not_nil(key)
      assert.is_truthy(string.match(key, "^batch_edge%-test%-1_%d+_%d+$"))
      break
    end
  end
  assert.is_true(found)
end)

runner:then_("^buffer overflow keeps only newest events and flushes (%d+) events total$", function(ctx, flushed)
  assert.equals(tonumber(flushed), ctx.flushed)
  local second_flush = saas_client.flush_events()
  assert.equals(0, second_flush)
end)

runner:then_("^events_sent_total has one success increment$", function(ctx)
  local count = 0
  for _, metric in ipairs(ctx.health_state.incs) do
    if metric.name == "fairvisor_events_sent_total" and metric.tags.status == "success" then
      count = count + 1
    end
  end
  assert.equals(1, count)
end)

runner:then_("^events_sent_total has one error increment$", function(ctx)
  local count = 0
  for _, metric in ipairs(ctx.health_state.incs) do
    if metric.name == "fairvisor_events_sent_total" and metric.tags.status == "error" then
      count = count + 1
    end
  end
  assert.equals(1, count)
end)

runner:then_("^the events payload flags clock skew$", function(ctx)
  local found = false
  for _, request in ipairs(ctx.http.requests) do
    if request.url == ctx.config.saas_url .. "/api/v1/edge/events" then
      found = true
      assert.is_true(request.body.clock_skew_suspected)
      assert.is_true(request.body.clock_skew_seconds > 10)
    end
  end
  assert.is_true(found)
end)

runner:then_("^backoff suppresses immediate retry and allows retry after (.+) seconds$", function(ctx, seconds)
  local heartbeat_calls = 0
  for _, request in ipairs(ctx.http.requests) do
    if request.url == ctx.config.saas_url .. "/api/v1/edge/heartbeat" then
      heartbeat_calls = heartbeat_calls + 1
    end
  end
  assert.equals(1, heartbeat_calls)

  ctx.timers[1].fn(false)

  local heartbeat_calls_after_immediate = 0
  for _, request in ipairs(ctx.http.requests) do
    if request.url == ctx.config.saas_url .. "/api/v1/edge/heartbeat" then
      heartbeat_calls_after_immediate = heartbeat_calls_after_immediate + 1
    end
  end
  assert.equals(1, heartbeat_calls_after_immediate)

  ctx.time.advance_time(tonumber(seconds))
  ctx.timers[1].fn(false)

  local heartbeat_calls_after_wait = 0
  for _, request in ipairs(ctx.http.requests) do
    if request.url == ctx.config.saas_url .. "/api/v1/edge/heartbeat" then
      heartbeat_calls_after_wait = heartbeat_calls_after_wait + 1
    end
  end
  assert.equals(2, heartbeat_calls_after_wait)
end)

runner:feature_file_relative("features/saas_client.feature")
