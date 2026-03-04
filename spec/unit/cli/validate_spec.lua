package.path = "./cli/?.lua;./cli/?/init.lua;./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local validate_command = require("cli.commands.validate")
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
        if content == [[{"version":"1","policies":[]}]] then
          return { version = "1", policies = {} }
        end

        if content == [[{"version":"1","policies":[{"id":"p1","spec":{"rules":[]}}]}]] then
          return {
            version = "1",
            policies = {
              { id = "p1", spec = { rules = {} } },
            },
          }
        end

        error("invalid json")
      end,
    }
  end
end

runner:given("^a valid policy bundle file$", function(ctx)
  ctx.file = "./validate_valid_policy.json"
  _write(ctx.file, [[{"version":"1","policies":[]}]] )
  _install_cjson_stub()
end)

runner:given("^bundle loader validate returns success$", function()
  _cleanup_stub("fairvisor.bundle_loader")
  package.preload["fairvisor.bundle_loader"] = function()
    return {
      validate = function(_bundle)
        return true
      end,
    }
  end
end)

runner:when("^I run fairvisor validate on the file$", function(ctx)
  ctx.ok, ctx.code = validate_command.run({ "validate", ctx.file })
end)

runner:then_("^validate exits with code 0$", function(ctx)
  assert.is_true(ctx.ok)
  assert.equals(0, ctx.code)
end)

runner:given("^an invalid JSON policy file$", function(ctx)
  ctx.file = "./validate_invalid_json.json"
  _write(ctx.file, [[{"version": }]])
  _install_cjson_stub()
end)

runner:then_("^validate exits with code 1$", function(ctx)
  assert.is_nil(ctx.ok)
  assert.equals(1, ctx.code)
end)

runner:given("^a syntactically valid policy file$", function(ctx)
  ctx.file = "./validate_schema_policy.json"
  _write(ctx.file, [[{"version":"1","policies":[{"id":"p1","spec":{"rules":[]}}]}]])
  _install_cjson_stub()
end)

runner:given("^bundle loader validate returns schema errors with paths$", function()
  _cleanup_stub("fairvisor.bundle_loader")
  package.preload["fairvisor.bundle_loader"] = function()
    return {
      validate = function(_bundle)
        return nil, {
          { path = "$.policies[0].spec.rules[0]", message = "rule is required" },
        }
      end,
    }
  end
end)

runner:given("^bundle loader only exposes validate_bundle and it returns no errors$", function()
  _cleanup_stub("fairvisor.bundle_loader")
  package.preload["fairvisor.bundle_loader"] = function()
    return {
      validate_bundle = function(_bundle)
        return {}
      end,
    }
  end
end)

runner:then_("^validate reports failure for schema errors$", function(ctx)
  assert.is_nil(ctx.ok)
  assert.equals(1, ctx.code)
end)

local ok, err = runner:feature([[
Feature: fairvisor validate command
  Rule: Policy files are validated via bundle_loader
    Scenario: Valid policy returns success
      Given a valid policy bundle file
      And bundle loader validate returns success
      When I run fairvisor validate on the file
      Then validate exits with code 0

    Scenario: Invalid JSON returns validation error
      Given an invalid JSON policy file
      And bundle loader validate returns success
      When I run fairvisor validate on the file
      Then validate exits with code 1

    Scenario: Schema validation errors return failure
      Given a syntactically valid policy file
      And bundle loader validate returns schema errors with paths
      When I run fairvisor validate on the file
      Then validate reports failure for schema errors

    Scenario: validate command supports validate_bundle fallback
      Given a valid policy bundle file
      And bundle loader only exposes validate_bundle and it returns no errors
      When I run fairvisor validate on the file
      Then validate exits with code 0
]])

assert.is_true(ok)
assert.is_nil(err)

teardown(function()
  os.remove("./validate_valid_policy.json")
  os.remove("./validate_invalid_json.json")
  os.remove("./validate_schema_policy.json")
  _cleanup_stub("fairvisor.bundle_loader")
  _cleanup_stub("cjson")
end)
