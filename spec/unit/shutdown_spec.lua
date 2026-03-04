package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _reload_shutdown()
  package.loaded["fairvisor.shutdown"] = nil
  return require("fairvisor.shutdown")
end

runner:given("^the shutdown test ngx environment is reset$", function(ctx)
  ctx.logs = {}
  ctx.timer = {}
  ctx.flush_called = 0

  ctx.ngx = {
    ERR = 1,
    NOTICE = 2,
    log = function(_, ...)
      ctx.logs[#ctx.logs + 1] = table.concat({ ... }, "")
    end,
    timer = {
      at = function(delay, callback)
        ctx.timer.delay = delay
        ctx.timer.callback = callback
        return true
      end,
    },
  }
  _G.ngx = ctx.ngx
end)

runner:given("^the shutdown timer registration fails$", function(ctx)
  ngx.timer.at = function()
    return nil, "timer failed"
  end
end)

runner:given("^a saas client flushes (%d+) events$", function(ctx, flushed)
  ctx.saas_client = {
    flush_events = function()
      ctx.flush_called = ctx.flush_called + 1
      return tonumber(flushed), nil
    end,
  }
end)

runner:given('^a saas client flush fails with "([^"]+)"$', function(ctx, err)
  ctx.saas_client = {
    flush_events = function()
      ctx.flush_called = ctx.flush_called + 1
      return nil, err
    end,
  }
end)

runner:given("^a health dependency exists$", function(ctx)
  ctx.health_called = 0
  ctx.health = {
    set_shutting_down = function()
      ctx.health_called = ctx.health_called + 1
    end,
  }
end)

runner:when("^I initialize shutdown module$", function(ctx)
  if ctx.ngx then
    _G.ngx = ctx.ngx
  end
  ctx.shutdown = _reload_shutdown()
  if ctx.ngx then
    _G.ngx = ctx.ngx
  end
  local deps = {
    saas_client = ctx.saas_client,
    health = ctx.health,
  }
  if ctx.ngx then
    deps.ngx = ctx.ngx
  end
  ctx.ok, ctx.err = ctx.shutdown.init(deps)
end)

runner:when("^I trigger shutdown via timer premature=true$", function(ctx)
  if ctx.ngx then
    _G.ngx = ctx.ngx
  end
  ctx.timer.callback(true)
end)

runner:when("^I call shutdown handler directly$", function(ctx)
  if ctx.ngx then
    _G.ngx = ctx.ngx
  end
  ctx.shutdown = ctx.shutdown or _reload_shutdown()
  ctx.shutdown.shutdown_handler()
end)

runner:then_("^initialization succeeds$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
end)

runner:then_('^initialization fails with "([^"]+)"$', function(ctx, expected)
  assert.is_nil(ctx.ok)
  assert.equals(expected, ctx.err)
end)

runner:then_("^a watchdog timer is registered$", function(ctx)
  assert.is_truthy(ctx.timer.callback)
  assert.equals(31536000, ctx.timer.delay)
end)

runner:then_("^the saas flush is called once$", function(ctx)
  assert.equals(1, ctx.flush_called)
end)

runner:then_("^health shutdown marker is called once$", function(ctx)
  assert.equals(1, ctx.health_called)
end)

runner:then_('^logs contain "([^"]+)"$', function(ctx, expected)
  local found = false
  for _, line in ipairs(ctx.logs) do
    if string.find(line, expected, 1, true) then
      found = true
      break
    end
  end
  assert.is_true(found)
end)

runner:feature([[
Feature: Graceful shutdown behavior
  Rule: Shutdown init must register a worker-shutdown watchdog
    Scenario: Init registers timer and executes flush on premature timer callback
      Given the shutdown test ngx environment is reset
      And a saas client flushes 7 events
      And a health dependency exists
      When I initialize shutdown module
      Then initialization succeeds
      And a watchdog timer is registered
      When I trigger shutdown via timer premature=true
      Then the saas flush is called once
      And health shutdown marker is called once
      And logs contain "graceful_shutdown_initiated"
      And logs contain "flushed_events=7"
      And logs contain "shutdown_complete"

    Scenario: Flush failures are logged and do not crash shutdown
      Given the shutdown test ngx environment is reset
      And a saas client flush fails with "upstream timeout"
      When I initialize shutdown module
      Then initialization succeeds
      When I trigger shutdown via timer premature=true
      Then the saas flush is called once
      And logs contain "event_flush_failed"
      And logs contain "shutdown_complete"

    Scenario: Timer registration error is returned from init
      Given the shutdown test ngx environment is reset
      And the shutdown timer registration fails
      When I initialize shutdown module
      Then initialization fails with "timer failed"

    Scenario: Shutdown handler works without dependencies
      Given the shutdown test ngx environment is reset
      When I call shutdown handler directly
      Then logs contain "graceful_shutdown_initiated"
      And logs contain "shutdown_complete"
]])
