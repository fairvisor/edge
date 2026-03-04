package.path = "./cli/?.lua;./cli/?/init.lua;./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local connect_command = require("cli.commands.connect")
local output = require("cli.lib.output")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })
local _original_print_warning = output.print_warning

local function _read(path)
  local handle = io.open(path, "r")
  if not handle then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function _cleanup_stub(name)
  package.loaded[name] = nil
  package.preload[name] = nil
end

runner:given("^resty%.http and cjson test doubles are installed$", function(ctx)
  _cleanup_stub("resty.http")
  _cleanup_stub("cjson")

  package.preload["cjson"] = function()
    return {
      encode = function(obj)
        return '{"version":"' .. (obj.version or "") .. '"}'
      end,
      decode = function(body)
        if body == "{\"edge_id\":\"edge-123\"}" then
          return { edge_id = "edge-123" }
        end
        return {}
      end,
    }
  end

  package.preload["resty.http"] = function()
    return {
      new = function()
        return {
          request_uri = function(_, uri, opts)
            if uri:find("/api/v1/edge/register", 1, true) then
              if opts and opts.headers and opts.headers.Authorization == "Bearer good-token" then
                return { status = 200, body = "{\"edge_id\":\"edge-123\"}" }
              end
              return { status = 401, body = "{}" }, "unauthorized"
            end

            if uri:find("/api/v1/edge/config", 1, true) then
              if ctx.config_status then
                return { status = ctx.config_status, body = "{}" }
              end
              return { status = 200, body = "{\"version\":\"1\",\"policies\":[]}" }
            end

            return nil, "unknown uri"
          end,
        }
      end,
    }
  end

  ctx.output_file = "./connect_edge.env"
  os.remove(ctx.output_file)
end)

runner:given("^connect output warnings are captured$", function(ctx)
  ctx.warning_messages = {}
  output.print_warning = function(message)
    ctx.warning_messages[#ctx.warning_messages + 1] = message
  end
end)

runner:given("^config endpoint returns HTTP 500$", function(ctx)
  ctx.config_status = 500
end)

runner:when("^I run fairvisor connect with explicit token and output$", function(ctx)
  ctx.ok, ctx.code = connect_command.run({
    "connect",
    "--token=good-token",
    "--url=https://api.fairvisor.test",
    "--output=" .. ctx.output_file,
  })
end)

runner:then_("^connect succeeds with code 0$", function(ctx)
  assert.is_true(ctx.ok)
  assert.equals(0, ctx.code)
end)

runner:then_("^the edge env file is written with credentials$", function(ctx)
  local content = _read(ctx.output_file)
  assert.is_truthy(content)
  assert.is_truthy(content:find("FAIRVISOR_EDGE_ID=edge-123", 1, true))
  assert.is_truthy(content:find("FAIRVISOR_EDGE_TOKEN=good-token", 1, true))
end)

runner:when("^I run fairvisor connect with bad token$", function(ctx)
  ctx.ok, ctx.code = connect_command.run({
    "connect",
    "--token=bad-token",
    "--url=https://api.fairvisor.test",
    "--output=" .. ctx.output_file,
  })
end)

runner:then_("^connect fails with connection exit code 2$", function(ctx)
  assert.is_nil(ctx.ok)
  assert.equals(2, ctx.code)
end)

runner:then_("^a warning mentions initial policy bundle download failure$", function(ctx)
  local found = false
  for _, message in ipairs(ctx.warning_messages or {}) do
    if type(message) == "string" and message:find("Could not download initial policy bundle", 1, true) then
      found = true
      break
    end
  end
  assert.is_true(found)
end)

local ok, err = runner:feature([[
Feature: fairvisor connect command
  Rule: SaaS registration writes local credentials
    Scenario: Valid token registers edge and writes env file
      Given resty.http and cjson test doubles are installed
      When I run fairvisor connect with explicit token and output
      Then connect succeeds with code 0
      And the edge env file is written with credentials

    Scenario: Invalid token returns connection failure
      Given resty.http and cjson test doubles are installed
      When I run fairvisor connect with bad token
      Then connect fails with connection exit code 2

    Scenario: Config download failure is surfaced as warning
      Given resty.http and cjson test doubles are installed
      And connect output warnings are captured
      And config endpoint returns HTTP 500
      When I run fairvisor connect with explicit token and output
      Then connect succeeds with code 0
      And a warning mentions initial policy bundle download failure
]])

assert.is_true(ok)
assert.is_nil(err)

teardown(function()
  os.remove("./connect_edge.env")
  _cleanup_stub("resty.http")
  _cleanup_stub("cjson")
  output.print_warning = _original_print_warning
end)
