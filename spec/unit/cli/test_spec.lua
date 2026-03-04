package.path = "./cli/?.lua;./cli/?/init.lua;./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local test_command = require("cli.commands.test")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _write(path, content)
  local handle = assert(io.open(path, "w"))
  handle:write(content)
  handle:close()
end

local function _cleanup_stub(name)
  package.loaded[name] = nil
  package.preload[name] = nil
end

local function _install_cjson_stub()
  _cleanup_stub("cjson")
  package.preload["cjson"] = function()
    return {
      decode = function(content)
        if content:find("\"policies\"", 1, true) then
          return {
            version = "1",
            policies = {
              {
                id = "p1",
                spec = {
                  selector = { pathPrefix = "/api/", methods = { "GET" } },
                  rules = {},
                },
              },
            },
          }
        end

        if content:find("\"method\":\"GET\"", 1, true) then
          return {
            { method = "GET", path = "/a", headers = {}, query_params = {}, ip_address = "127.0.0.1", user_agent = "test" },
            { method = "POST", path = "/b", headers = {}, query_params = {}, ip_address = "127.0.0.1", user_agent = "test" },
          }
        end

        error("invalid json")
      end,
    }
  end
end

runner:given("^a policy file for dry%-run testing$", function(ctx)
  ctx.file = "./test_policy.json"
  _write(ctx.file, [[{"version":"1","policies":[{"id":"p1","spec":{"selector":{"pathPrefix":"/api/"},"rules":[]}}]}]])
  _install_cjson_stub()
end)

runner:given("^bundle loader and rule engine test doubles are installed$", function(ctx)
  _cleanup_stub("fairvisor.bundle_loader")
  _cleanup_stub("fairvisor.rule_engine")

  ctx.init_called = false
  ctx.evaluate_calls = 0

  package.preload["fairvisor.bundle_loader"] = function()
    return {
      load_from_string = function(content)
        return {
          policies = {
            {
              id = "p1",
              spec = {
                selector = { pathPrefix = "/api/", methods = { "GET" } },
                rules = {},
              },
            },
          },
          raw = content,
        }
      end,
    }
  end

  package.preload["fairvisor.rule_engine"] = function()
    return {
      init = function(_opts)
        ctx.init_called = true
      end,
      evaluate = function(_request, _bundle)
        ctx.evaluate_calls = ctx.evaluate_calls + 1
        return {
          action = "allow",
          reason = "dry_run",
          rule_name = "rule1",
        }
      end,
    }
  end
end)

runner:when("^I run fairvisor test on the policy file$", function(ctx)
  ctx.ok, ctx.code = test_command.run({ "test", ctx.file })
end)

runner:then_("^the dry%-run exits with code 0$", function(ctx)
  assert.is_true(ctx.ok)
  assert.equals(0, ctx.code)
end)

runner:then_("^rule engine init and evaluate are used$", function(ctx)
  assert.is_true(ctx.init_called)
  assert.equals(1, ctx.evaluate_calls)
end)

runner:given("^a mock requests file with two requests$", function(ctx)
  ctx.requests_file = "./test_requests.json"
  _write(ctx.requests_file, [[
[
  {"method":"GET","path":"/a","headers":{},"query_params":{},"ip_address":"127.0.0.1","user_agent":"test"},
  {"method":"POST","path":"/b","headers":{},"query_params":{},"ip_address":"127.0.0.1","user_agent":"test"}
]
]])
  _install_cjson_stub()
end)

runner:when("^I run fairvisor test with explicit requests file$", function(ctx)
  ctx.ok, ctx.code = test_command.run({ "test", ctx.file, "--requests=" .. ctx.requests_file })
end)

runner:then_("^evaluate is called for each provided request$", function(ctx)
  assert.equals(2, ctx.evaluate_calls)
end)

local ok, err = runner:feature([[
Feature: fairvisor test command
  Rule: Dry-run evaluates requests through rule_engine
    Scenario: Generated requests flow through real evaluation interface
      Given a policy file for dry-run testing
      And bundle loader and rule engine test doubles are installed
      When I run fairvisor test on the policy file
      Then the dry-run exits with code 0
      And rule engine init and evaluate are used

    Scenario: Explicit request fixtures are evaluated one by one
      Given a policy file for dry-run testing
      And bundle loader and rule engine test doubles are installed
      And a mock requests file with two requests
      When I run fairvisor test with explicit requests file
      Then the dry-run exits with code 0
      And evaluate is called for each provided request
]])

assert.is_true(ok)
assert.is_nil(err)

teardown(function()
  os.remove("./test_policy.json")
  os.remove("./test_requests.json")
  _cleanup_stub("fairvisor.bundle_loader")
  _cleanup_stub("fairvisor.rule_engine")
  _cleanup_stub("cjson")
end)
