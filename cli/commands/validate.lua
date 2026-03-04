local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring

local args = require("cli.lib.args")
local output = require("cli.lib.output")

local _M = {}

local function _read_file(path)
  if path == "-" then
    return io.read("*a")
  end

  local handle, err = io.open(path, "r")
  if not handle then
    return nil, err
  end

  local content = handle:read("*a")
  handle:close()
  return content
end

local function _decode_json(content)
  local ok, cjson = pcall(require, "cjson")
  if not ok then
    return nil, "cjson module is not available"
  end

  local decode_ok, parsed = pcall(cjson.decode, content)
  if not decode_ok then
    return nil, parsed
  end

  return parsed
end

local function _count_rules(bundle)
  local total = 0
  local policies = bundle.policies or {}
  for _, policy in ipairs(policies) do
    local spec = policy.spec or {}
    local rules = spec.rules or {}
    total = total + #rules
  end
  return total
end

local function _validate_algorithm_config(rule)
  if type(rule) ~= "table" then
    return nil, "rule must be a table"
  end

  local algorithm = rule.algorithm or (rule.config and rule.config.algorithm)
  if algorithm == "token_bucket" then
    local ok, token_bucket = pcall(require, "fairvisor.token_bucket")
    if ok and token_bucket.validate_config and type(rule.config) == "table" then
      local config = {}
      for key, value in pairs(rule.config) do
        config[key] = value
      end
      return token_bucket.validate_config(config)
    end
  end

  return true
end

local function _normalize_validation_result(valid, validation_errors)
  if valid == true then
    return true, {}
  end

  if type(valid) == "table" and validation_errors == nil then
    if #valid == 0 then
      return true, {}
    end
    return nil, valid
  end

  if type(validation_errors) == "table" then
    return nil, validation_errors
  end

  if validation_errors ~= nil then
    return nil, { tostring(validation_errors) }
  end

  return nil, { "validation failed" }
end

function _M.run(argv)
  local parsed = args.parse(argv, 2)
  local file = parsed.positional[1]
  if not file then
    output.print_error("Usage: fairvisor validate <file|->")
    return nil, 3
  end

  local content, read_err = _read_file(file)
  if not content then
    output.print_error("Cannot read file: " .. read_err)
    return nil, 1
  end

  local bundle, parse_err = _decode_json(content)
  if not bundle then
    output.print_error("Invalid JSON: " .. parse_err)
    return nil, 1
  end

  local ok, bundle_loader = pcall(require, "fairvisor.bundle_loader")
  if not ok then
    output.print_error("bundle_loader module is unavailable: " .. bundle_loader)
    return nil, 1
  end

  local validator = bundle_loader.validate
  if type(validator) ~= "function" and type(bundle_loader.validate_bundle) == "function" then
    validator = bundle_loader.validate_bundle
  end

  if type(validator) ~= "function" then
    output.print_error("bundle_loader.validate() / validate_bundle() is not available")
    return nil, 1
  end

  local valid, validation_errors = validator(bundle)
  valid, validation_errors = _normalize_validation_result(valid, validation_errors)
  if not valid then
    local errors = validation_errors
    for _, err in ipairs(errors) do
      if type(err) == "table" then
        output.print_error((err.path or "$") .. ": " .. (err.message or "validation error"))
      else
        output.print_error(tostring(err))
      end
    end
    return nil, 1
  end

  local policies = bundle.policies or {}
  for _, policy in ipairs(policies) do
    local spec = policy.spec or {}
    local rules = spec.rules or {}
    for _, rule in ipairs(rules) do
      local alg_ok, alg_err = _validate_algorithm_config(rule)
      if not alg_ok then
        output.print_warning((policy.id or "unknown_policy") .. "/" .. (rule.name or "unknown_rule") .. ": " .. alg_err)
      end
    end
  end

  output.print_line("Valid: " .. #policies .. " policies, " .. _count_rules(bundle) .. " rules")
  return true, 0
end

return _M
