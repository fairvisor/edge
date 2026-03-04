local gmatch = string.gmatch
local match = string.match

local args = require("cli.lib.args")
local output = require("cli.lib.output")

local _M = {}

local function _parse_metric(metrics_text, metric_name)
  if not metrics_text then
    return "unknown"
  end

  for line in gmatch(metrics_text, "[^\r\n]+") do
    if match(line, "^" .. metric_name .. "[%s{]") then
      local value = match(line, "([%+%-]?[%d%.eE]+)%s*$")
      return value or "unknown"
    end
  end

  return "unknown"
end

function _M.run(argv)
  local parsed = args.parse(argv, 2)
  local edge_url = args.get_flag(parsed, "edge-url")
    or os.getenv("FAIRVISOR_EDGE_URL")
    or "http://localhost:8080"
  local format = args.get_flag(parsed, "format", "table")

  local ok_http, http = pcall(require, "resty.http")
  if not ok_http then
    output.print_error("lua-resty-http is not available: " .. http)
    return nil, 1
  end

  local httpc = http.new()
  local health_res = httpc:request_uri(edge_url .. "/readyz")
  if not health_res then
    output.print_error("Edge not reachable at " .. edge_url)
    return nil, 2
  end

  local metrics_res = httpc:request_uri(edge_url .. "/metrics")
  local metrics_body = metrics_res and metrics_res.body or ""

  local data = {
    status = (health_res.status == 200 and "ready") or "not ready",
    policy_version = _parse_metric(metrics_body, "fairvisor_bundle_version"),
    saas = (_parse_metric(metrics_body, "fairvisor_saas_reachable") == "1") and "connected" or "disconnected",
    decisions = _parse_metric(metrics_body, "fairvisor_decisions_total"),
  }

  if format == "json" then
    local ok_emit, emit_err = output.emit(data, "json")
    if not ok_emit then
      output.print_error(emit_err)
      return nil, 1
    end
    return true, 0
  end

  output.print_line("Status:         " .. data.status)
  output.print_line("Policy version: " .. data.policy_version)
  output.print_line("SaaS:           " .. data.saas)
  output.print_line("Decisions:      " .. data.decisions)
  return true, 0
end

return _M
