local ipairs = ipairs
local tostring = tostring
local type = type

local args = require("cli.lib.args")
local output = require("cli.lib.output")

local _M = {}

local function _read_file(path)
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

  local decode_ok, decoded = pcall(cjson.decode, content)
  if not decode_ok then
    return nil, decoded
  end

  return decoded
end

local function _generate_mock_requests(bundle)
  local requests = {}
  local policies = bundle.policies or {}

  for _, policy in ipairs(policies) do
    local spec = policy.spec or {}
    local selector = spec.selector or {}
    local methods = selector.methods

    requests[#requests + 1] = {
      method = methods and methods[1] or "GET",
      path = selector.pathExact or selector.pathPrefix or "/",
      headers = {},
      query_params = {},
      ip_address = "127.0.0.1",
      user_agent = "fairvisor-cli/test",
    }
  end

  if #requests == 0 then
    requests[1] = {
      method = "GET",
      path = "/",
      headers = {},
      query_params = {},
      ip_address = "127.0.0.1",
      user_agent = "fairvisor-cli/test",
    }
  end

  return requests
end

local function _load_requests(path)
  local content, err = _read_file(path)
  if not content then
    return nil, err
  end

  local requests, decode_err = _decode_json(content)
  if not requests then
    return nil, decode_err
  end

  if type(requests) ~= "table" then
    return nil, "requests payload must be a JSON array"
  end

  return requests
end

local function _summarize(results)
  local summary = {
    total = #results,
    allow = 0,
    reject = 0,
    other = 0,
  }

  for _, result in ipairs(results) do
    local action = result.action
    if action == "allow" then
      summary.allow = summary.allow + 1
    elseif action == "reject" then
      summary.reject = summary.reject + 1
    else
      summary.other = summary.other + 1
    end
  end

  return summary
end

function _M.run(argv)
  local parsed = args.parse(argv, 2)
  local file = parsed.positional[1]
  if not file then
    output.print_error("Usage: fairvisor test <file> [--requests=<file>] [--format=table|json]")
    return nil, 3
  end

  local ok_loader, bundle_loader = pcall(require, "fairvisor.bundle_loader")
  if not ok_loader then
    output.print_error("bundle_loader module is unavailable: " .. bundle_loader)
    return nil, 1
  end

  local ok_engine, rule_engine = pcall(require, "fairvisor.rule_engine")
  if not ok_engine then
    output.print_error("rule_engine module is unavailable: " .. rule_engine)
    return nil, 1
  end

  local content, read_err = _read_file(file)
  if not content then
    output.print_error("Cannot read file: " .. read_err)
    return nil, 1
  end

  if type(bundle_loader.load_from_string) ~= "function" then
    output.print_error("bundle_loader.load_from_string() is not available")
    return nil, 1
  end

  local bundle, load_err = bundle_loader.load_from_string(content, nil, nil)
  if not bundle then
    output.print_error("Bundle load failed: " .. load_err)
    return nil, 1
  end

  local ok_mock, mock_ngx = pcall(require, "spec.helpers.mock_ngx")
  if not ok_mock then
    output.print_error("mock_ngx helper is unavailable: " .. mock_ngx)
    return nil, 1
  end

  if type(rule_engine.init) ~= "function" or type(rule_engine.evaluate) ~= "function" then
    output.print_error("rule_engine.init() and rule_engine.evaluate() are required")
    return nil, 1
  end

  local mock_health = {
    is_circuit_open = function()
      return false
    end,
  }
  rule_engine.init({
    dict = mock_ngx.mock_shared_dict(),
    health = mock_health,
  })

  local requests_file = args.get_flag(parsed, "requests")
  local requests
  if requests_file then
    requests, read_err = _load_requests(requests_file)
    if not requests then
      output.print_error("Cannot load requests: " .. read_err)
      return nil, 1
    end
  else
    requests = _generate_mock_requests(bundle)
  end

  local results = {}
  for index, request in ipairs(requests) do
    local decision = rule_engine.evaluate(request, bundle)
    local action = decision and decision.action
    if not action and decision and decision.allowed ~= nil then
      action = decision.allowed and "allow" or "reject"
    end
    action = action or "unknown"

    results[#results + 1] = {
      index = index,
      method = request.method,
      path = request.path,
      action = action,
      reason = decision and decision.reason or "",
      rule = decision and decision.rule_name or "",
    }

    output.print_line(index .. ". " .. tostring(request.method) .. " " .. tostring(request.path) .. " -> " .. action)
  end

  local summary = _summarize(results)
  local format = args.get_flag(parsed, "format", "table")
  if format == "json" then
    local ok_emit, emit_err = output.emit({ results = results, summary = summary }, "json")
    if not ok_emit then
      output.print_error(emit_err)
      return nil, 1
    end
  else
    output.print_line("Summary: total=" .. summary.total
      .. " allow=" .. summary.allow .. " reject=" .. summary.reject .. " other=" .. summary.other)
  end

  return true, 0
end

return _M
