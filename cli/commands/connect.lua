local args = require("cli.lib.args")
local output = require("cli.lib.output")

local _M = {}

local EDGE_VERSION = require("cli.version_const")
local DEFAULT_SAAS_URL = "https://api.fairvisor.com"
local DEFAULT_OUTPUT = "/etc/fairvisor/edge.env"

local function _write_file(path, content)
  local handle, err = io.open(path, "w")
  if not handle then
    return nil, err
  end

  handle:write(content)
  handle:close()
  return true
end

local function _write_env_file(path, env)
  local lines = {
    "FAIRVISOR_EDGE_ID=" .. (env.FAIRVISOR_EDGE_ID or ""),
    "FAIRVISOR_EDGE_TOKEN=" .. (env.FAIRVISOR_EDGE_TOKEN or ""),
    "FAIRVISOR_SAAS_URL=" .. (env.FAIRVISOR_SAAS_URL or ""),
    "",
  }
  return _write_file(path, table.concat(lines, "\n"))
end

local function _prompt(label, fallback)
  io.write(label)
  local value = io.read()
  if (not value or value == "") and fallback then
    return fallback
  end
  return value
end

local function _is_non_interactive()
  return os.getenv("CI") == "true" or os.getenv("FAIRVISOR_NON_INTERACTIVE") == "1"
end

function _M.run(argv)
  local parsed = args.parse(argv, 2)
  local token = args.get_flag(parsed, "token") or os.getenv("FAIRVISOR_EDGE_TOKEN")
  if not token or token == "" then
    if _is_non_interactive() then
      output.print_error("token is required (set FAIRVISOR_EDGE_TOKEN or use --token=)")
      return nil, 3
    end
    token = _prompt("Enter your edge token: ")
  end

  if not token or token == "" then
    output.print_error("token is required")
    return nil, 3
  end

  local saas_url = args.get_flag(parsed, "url") or args.get_flag(parsed, "saas-url")
    or os.getenv("FAIRVISOR_SAAS_URL")
  if not saas_url or saas_url == "" then
    if _is_non_interactive() then
      output.print_error("SaaS URL is required (set FAIRVISOR_SAAS_URL or use --url=)")
      return nil, 3
    end
    saas_url = _prompt("Enter SaaS URL [https://api.fairvisor.com]: ", DEFAULT_SAAS_URL)
  end

  local ok_http, http = pcall(require, "resty.http")
  if not ok_http then
    output.print_error("lua-resty-http is not available: " .. http)
    return nil, 1
  end

  local ok_json, cjson = pcall(require, "cjson")
  if not ok_json then
    output.print_error("cjson is not available: " .. cjson)
    return nil, 1
  end

  local httpc = http.new()
  local response, req_err = httpc:request_uri(saas_url .. "/api/v1/edge/register", {
    method = "POST",
    body = cjson.encode({ version = EDGE_VERSION }),
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. token,
    },
  })

  if not response or response.status ~= 200 then
    output.print_error("Connection failed: " .. (req_err or (response and ("HTTP " .. response.status) or "unknown error")))
    return nil, 2
  end

  local decode_ok, payload = pcall(cjson.decode, response.body)
  if not decode_ok then
    output.print_error("Connection failed: cannot decode response")
    return nil, 2
  end

  local edge_id = payload.edge_id
  if not edge_id then
    output.print_error("Connection failed: missing edge_id in response")
    return nil, 2
  end

  local output_path = args.get_flag(parsed, "output", DEFAULT_OUTPUT)
  local env = {
    FAIRVISOR_EDGE_ID = edge_id,
    FAIRVISOR_EDGE_TOKEN = token,
    FAIRVISOR_SAAS_URL = saas_url,
  }

  local ok_write = _write_env_file(output_path, env)
  if not ok_write then
    local fallback_ok, fallback_err = _write_env_file("./edge.env", env)
    if not fallback_ok then
      output.print_error("Cannot write env file: " .. fallback_err)
      return nil, 1
    end
    output.print_warning("No write access to " .. output_path .. ", wrote to ./edge.env")
  end

  local cfg_res, cfg_req_err = httpc:request_uri(saas_url .. "/api/v1/edge/config", {
    headers = {
      ["Authorization"] = "Bearer " .. token,
    },
  })

  if cfg_res and cfg_res.status == 200 then
    local saved, cfg_err = _write_file("/etc/fairvisor/policy.json", cfg_res.body)
    if saved then
      output.print_line("Downloaded initial policy bundle")
    elseif cfg_err then
      output.print_warning("Could not write /etc/fairvisor/policy.json: " .. cfg_err)
    end
  elseif cfg_res then
    output.print_warning("Could not download initial policy bundle: HTTP " .. tostring(cfg_res.status))
  else
    output.print_warning("Could not download initial policy bundle: " .. tostring(cfg_req_err or "unknown error"))
  end

  output.print_line("Connected. Edge ID: " .. edge_id)
  return true, 0
end

return _M
