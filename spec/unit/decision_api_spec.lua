package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local decision_api = require("fairvisor.decision_api")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _encode_base64(raw)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local bytes = { string.byte(raw, 1, #raw) }
  local out = {}
  local i = 1

  while i <= #bytes do
    local b1 = bytes[i]
    local b2 = bytes[i + 1]
    local b3 = bytes[i + 2]

    local n = (b1 or 0) * 65536 + (b2 or 0) * 256 + (b3 or 0)
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64

    out[#out + 1] = alphabet:sub(c1 + 1, c1 + 1)
    out[#out + 1] = alphabet:sub(c2 + 1, c2 + 1)

    if b2 then
      out[#out + 1] = alphabet:sub(c3 + 1, c3 + 1)
    else
      out[#out + 1] = "="
    end

    if b3 then
      out[#out + 1] = alphabet:sub(c4 + 1, c4 + 1)
    else
      out[#out + 1] = "="
    end

    i = i + 3
  end

  return table.concat(out)
end

local function _to_base64url(raw)
  local encoded = _encode_base64(raw)
  encoded = encoded:gsub("+", "-")
  encoded = encoded:gsub("/", "_")
  encoded = encoded:gsub("=+$", "")
  return encoded
end

runner:given("^the decision api dependencies are initialized$", function(ctx)
  mock_ngx.setup_ngx()

  local headers = {}
  local uri_args = {}

  ngx.req = {
    get_headers = function()
      return headers
    end,
    get_uri_args = function()
      return uri_args
    end,
  }

  ngx.var = {
    request_method = "GET",
    uri = "/v1/decision",
    host = "edge.internal",
    remote_addr = "127.0.0.1",
  }

  ngx.header = {}
  ngx.ctx = {}

  ctx.decode_base64_map = {
    ["eyJzdWIiOiJ1c2VyLTEiLCJyb2xlIjoiYWRtaW4ifQ"] = '{"sub":"user-1","role":"admin"}',
    ["eyJzdWIiOiJ1c2VyLTEiLCJyb2xlIjoiYWRtaW4ifQ=="] = '{"sub":"user-1","role":"admin"}',
    ["eyJwbGFuIjoicHJvIiwidXNlcl9pZCI6NDJ9"] = '{"plan":"pro","user_id":42}',
  }
  ngx.decode_base64 = function(input)
    return ctx.decode_base64_map[input]
  end

  ngx.exit_calls = {}
  ngx.exit = function(code)
    ngx.exit_calls[#ngx.exit_calls + 1] = code
    return code
  end

  ngx.sleep_calls = {}
  ngx.sleep = function(seconds)
    ngx.sleep_calls[#ngx.sleep_calls + 1] = seconds
  end

  ngx.log_calls = {}
  ngx.log = function(level, ...)
    ngx.log_calls[#ngx.log_calls + 1] = { level = level, args = { ... } }
  end

  ctx.bundle = { id = "bundle-1" }

  ctx.bundle_loader = {
    get_current = function()
      return ctx.bundle
    end,
  }

  ctx.rule_engine = {
    evaluate = function(request_context, bundle)
      ctx.last_request_context = request_context
      ctx.last_bundle = bundle
      return ctx.decision
    end,
  }

  ctx.metric_calls = {}
  ctx.health = {
    inc = function(_, metric_name, labels, value)
      ctx.metric_calls[#ctx.metric_calls + 1] = {
        metric_name = metric_name,
        action = labels and labels.action or nil,
        policy_id = labels and labels.policy_id or nil,
        bucket = labels and labels.bucket or nil,
        labels = labels,
        value = value,
      }
    end,
  }

  ctx.env_overrides = {}
  ctx.original_getenv = os.getenv
end)

runner:given('^the mode is "([^"]+)"$', function(ctx, mode)
  os.getenv = function(key)
    if key == "FAIRVISOR_MODE" then
      return mode
    end
    return ctx.env_overrides and ctx.env_overrides[key] or nil
  end

  local ok, err = decision_api.init({
    bundle_loader = ctx.bundle_loader,
    rule_engine = ctx.rule_engine,
    health = ctx.health,
  })

  assert.is_true(ok)
  assert.is_nil(err)
end)

runner:given('^the mode is "([^"]+)" and retry jitter is "([^"]+)"$', function(ctx, mode, _jitter)
  -- Jitter is non-configurable (always deterministic); same as "the mode is X".
  os.getenv = function(key)
    if key == "FAIRVISOR_MODE" then return mode end
    return ctx.env_overrides and ctx.env_overrides[key] or nil
  end
  local ok, err = decision_api.init({
    bundle_loader = ctx.bundle_loader,
    rule_engine = ctx.rule_engine,
    health = ctx.health,
  })
  assert.is_true(ok)
  assert.is_nil(err)
end)

runner:given('^headers include "([^"]+)" as "([^"]+)"$', function(_, name, value)
  local headers = ngx.req.get_headers()
  headers[name] = value
end)

local function _normalize_base64url(b64url)
  local s = b64url:gsub("-", "+"):gsub("_", "/")
  local pad = (4 - (#s % 4)) % 4
  return s .. string.rep("=", pad)
end

runner:given('^headers include "Authorization" with JWT containing nested claims$', function(ctx)
  local payload = '{"sub":"user-nested","realm_access":{"roles":["a","b"]}}'
  local b64url = _to_base64url(payload)
  local normalized = _normalize_base64url(b64url)
  ctx.decode_base64_map[normalized] = payload
  local headers = ngx.req.get_headers()
  headers["Authorization"] = "Bearer a." .. b64url .. ".c"
end)

runner:given('^query param "([^"]+)" is "([^"]+)"$', function(_, name, value)
  local args = ngx.req.get_uri_args()
  args[name] = value
end)

runner:given('^request method is "([^"]+)" and path is "([^"]+)"$', function(_, method, path)
  ngx.var.request_method = method
  ngx.var.uri = path
end)

runner:given('^client ip is "([^"]+)"$', function(_, ip)
  ngx.var.remote_addr = ip
end)

runner:given('^nginx tor exit variable is "([^"]+)"$', function(_, value)
  ngx.var.is_tor_exit = value
end)

runner:given('^the rule engine decision is allow with headers limit "([^"]+)" remaining "([^"]+)" reset "([^"]+)"$',
  function(ctx, limit, remaining, reset)
    ctx.decision = {
      action = "allow",
      policy_id = "policy-a",
      headers = {
        ["RateLimit-Limit"] = limit,
        ["RateLimit-Remaining"] = remaining,
        ["RateLimit-Reset"] = reset,
      },
    }
  end
)

runner:given('^the rule engine decision is reject with reason "([^"]+)" and retry_after (%d+)$', function(ctx, reason, retry_after)
  local ra = tonumber(retry_after)
  ctx.decision = {
    action = "reject",
    policy_id = "policy-r",
    reason = reason,
    retry_after = ra,
    headers = {
      ["RateLimit-Limit"] = "10",
      ["RateLimit-Remaining"] = "0",
      ["RateLimit-Reset"] = tostring(retry_after),
      ["RateLimit"] = '"policy-r";r=0;t=' .. tostring(retry_after),
    },
  }
end)

runner:given('^the rule engine decision is reject with header retry_after (%d+) and reason "([^"]+)"$',
  function(ctx, retry_after, reason)
    local ra = tonumber(retry_after)
    ctx.decision = {
      action = "reject",
      policy_id = "policy-r",
      reason = reason,
      headers = {
        ["Retry-After"] = tostring(ra),
        ["RateLimit-Limit"] = "10",
        ["RateLimit-Remaining"] = "0",
        ["RateLimit-Reset"] = tostring(ra),
      },
    }
  end
)

runner:given('^the rule engine decision is throttle with delay_ms (%d+)$', function(ctx, delay_ms)
  ctx.decision = {
    action = "throttle",
    policy_id = "policy-t",
    delay_ms = tonumber(delay_ms),
    headers = {
      ["RateLimit-Limit"] = "25",
      ["RateLimit-Remaining"] = "24",
      ["RateLimit-Reset"] = "1",
    },
  }
end)

runner:given("^the rule engine decision is allow in shadow mode$", function(ctx)
  ctx.decision = {
    action = "allow",
    policy_id = "policy-shadow",
    mode = "shadow",
    headers = {
      ["RateLimit-Limit"] = "100",
      ["RateLimit-Remaining"] = "99",
      ["RateLimit-Reset"] = "1",
    },
  }
end)

runner:given("^the rule engine decision is allow with global overrides$", function(ctx)
  ctx.decision = {
    action = "allow",
    policy_id = "policy-override",
    headers = {
      ["X-Fairvisor-Global-Shadow"] = "true",
      ["X-Fairvisor-Global-Shadow-Reason"] = "incident-global-shadow",
      ["X-Fairvisor-Global-Shadow-Expires-At"] = "2030-01-01T00:00:00Z",
      ["X-Fairvisor-Kill-Switch-Override"] = "true",
      ["X-Fairvisor-Kill-Switch-Override-Reason"] = "incident-ks-override",
      ["X-Fairvisor-Kill-Switch-Override-Expires-At"] = "2030-01-01T00:00:00Z",
    },
  }
end)

runner:given("^no bundle is currently loaded$", function(ctx)
  ctx.bundle = nil
end)

runner:given("^math random returns ([%d%.]+)$", function(ctx, value)
  local random_value = tonumber(value)
  ctx.original_random = ctx.original_random or math.random
  math.random = function()
    return random_value
  end
end)

runner:given('^math random returns sequence "([^"]+)"$', function(ctx, values_csv)
  local values = {}
  for raw in string.gmatch(values_csv, "[^, ]+") do
    values[#values + 1] = tonumber(raw)
  end

  ctx.original_random = ctx.original_random or math.random
  local index = 0
  math.random = function()
    index = index + 1
    local value = values[index]
    if value == nil then
      return values[#values] or 0
    end
    return value
  end
end)

runner:when("^I decode the jwt payload from authorization header$", function(ctx)
  local auth = ngx.req.get_headers()["Authorization"]
  ctx.claims = decision_api.decode_jwt_payload(auth)
end)

runner:when("^I build request context$", function(ctx)
  ctx.request_context = decision_api.build_request_context()
end)

runner:when("^I run the access handler$", function(ctx)
  ctx.access_result = decision_api.access_handler()
end)

runner:when("^I run the access handler twice$", function(ctx)
  ctx.first_access_result = decision_api.access_handler()
  ctx.first_retry_after = tostring(ngx.header["Retry-After"])

  if ctx.decision and ctx.decision.headers then
    ctx.decision.headers["Retry-After"] = nil
  end

  ngx.header = {}
  ngx.status = nil
  ngx.exit_calls = {}

  ctx.second_access_result = decision_api.access_handler()
  ctx.second_retry_after = tostring(ngx.header["Retry-After"])
end)

runner:when('^I run the access handler for clients "([^"]+)" and "([^"]+)"$', function(ctx, first_ip, second_ip)
  ngx.var.remote_addr = first_ip
  ctx.first_access_result = decision_api.access_handler()
  ctx.first_retry_after = tostring(ngx.header["Retry-After"])

  if ctx.decision and ctx.decision.headers then
    ctx.decision.headers["Retry-After"] = nil
  end

  ngx.header = {}
  ngx.status = nil
  ngx.exit_calls = {}

  ngx.var.remote_addr = second_ip
  ctx.second_access_result = decision_api.access_handler()
  ctx.second_retry_after = tostring(ngx.header["Retry-After"])
end)

runner:when('^I collect retry after samples for clients "([^"]+)"$', function(ctx, clients_csv)
  ctx.retry_after_samples = {}

  for client_ip in string.gmatch(clients_csv, "[^, ]+") do
    ngx.var.remote_addr = client_ip

    if ctx.decision and ctx.decision.headers then
      ctx.decision.headers["Retry-After"] = nil
    end
    ngx.header = {}
    ngx.status = nil
    ngx.exit_calls = {}
    decision_api.access_handler()
    local first_retry_after = tostring(ngx.header["Retry-After"])

    if ctx.decision and ctx.decision.headers then
      ctx.decision.headers["Retry-After"] = nil
    end
    ngx.header = {}
    ngx.status = nil
    ngx.exit_calls = {}
    decision_api.access_handler()
    local second_retry_after = tostring(ngx.header["Retry-After"])

    ctx.retry_after_samples[#ctx.retry_after_samples + 1] = {
      client_ip = client_ip,
      first = first_retry_after,
      second = second_retry_after,
    }
  end
end)

runner:when("^I run the header filter handler$", function(ctx)
  ctx.header_filter_result = decision_api.header_filter_handler()
end)

runner:then_('^jwt claims contain sub "([^"]+)" and role "([^"]+)"$', function(ctx, sub, role)
  assert.equals(sub, ctx.claims.sub)
  assert.equals(role, ctx.claims.role)
end)

runner:then_('^jwt claims contain sub "([^"]+)"$', function(ctx, sub)
  assert.equals(sub, ctx.claims.sub)
end)

runner:then_('^jwt claims contain nested realm_access with roles "([^"]+)" and "([^"]+)"$', function(ctx, r1, r2)
  assert.is_table(ctx.claims.realm_access, "realm_access should be a table (nested JSON)")
  assert.is_table(ctx.claims.realm_access.roles, "realm_access.roles should be an array")
  assert.equals(r1, ctx.claims.realm_access.roles[1])
  assert.equals(r2, ctx.claims.realm_access.roles[2])
end)

runner:then_("^jwt claims are nil$", function(ctx)
  assert.is_nil(ctx.claims)
end)

runner:then_('^request context method is "([^"]+)" and path is "([^"]+)"$', function(ctx, method, path)
  assert.equals(method, ctx.request_context.method)
  assert.equals(path, ctx.request_context.path)
end)

runner:then_('^request context has user agent "([^"]+)" and client ip "([^"]+)"$', function(ctx, user_agent, ip)
  assert.equals(user_agent, ctx.request_context.user_agent)
  assert.equals(ip, ctx.request_context.ip_address)
end)

runner:then_('^request context host is "([^"]+)"$', function(ctx, host)
  assert.equals(host, ctx.request_context.host)
end)

runner:then_('^request context includes jwt claim plan "([^"]+)"$', function(ctx, plan)
  assert.equals(plan, ctx.request_context.jwt_claims.plan)
end)

runner:then_('^request context ip tor is "([^"]+)"$', function(ctx, expected)
  assert.equals(expected, ctx.request_context.ip_tor)
end)

runner:then_("^the request is rejected with status (%d+)$", function(_, status)
  assert.equals(tonumber(status), ngx.status)
  assert.equals(tonumber(status), ngx.exit_calls[#ngx.exit_calls])
end)

runner:then_("^the access phase proceeds without exiting$", function(_)
  assert.equals(0, #ngx.exit_calls)
end)

runner:then_('^response header "([^"]+)" is "([^"]+)"$', function(_, header_name, expected)
  assert.equals(expected, tostring(ngx.header[header_name]))
end)

runner:then_("^retry after header is between (%d+) and (%d+)$", function(_, min_value, max_value)
  local retry_after = tonumber(ngx.header["Retry-After"])
  assert.is_true(retry_after >= tonumber(min_value))
  assert.is_true(retry_after <= tonumber(max_value))
end)

runner:then_("^response includes all rate limit and fairvisor headers on reject$", function(_)
  assert.is_not_nil(ngx.header["RateLimit-Limit"], "RateLimit-Limit missing")
  assert.is_not_nil(ngx.header["RateLimit-Remaining"], "RateLimit-Remaining missing")
  assert.is_not_nil(ngx.header["RateLimit-Reset"], "RateLimit-Reset missing")
  assert.is_not_nil(ngx.header["RateLimit"], "RateLimit (structured) missing")
  assert.is_not_nil(ngx.header["Retry-After"], "Retry-After missing")
  assert.is_nil(ngx.header["X-Fairvisor-Reason"], "X-Fairvisor-Reason must be debug-only")
  assert.is_nil(ngx.header["X-Fairvisor-Policy"], "X-Fairvisor-Policy must be debug-only")
  assert.is_nil(ngx.header["X-Fairvisor-Rule"], "X-Fairvisor-Rule must be debug-only")
  assert.is_true((ngx.header["RateLimit"] or ""):find('"policy%-r";r=0;t=') ~= nil,
    "RateLimit should be structured with policy-r, r=0")
end)

runner:then_("^the reverse proxy headers are buffered in ngx ctx$", function(_)
  assert.is_not_nil(ngx.ctx.fairvisor_headers)
  assert.equals("25", ngx.ctx.fairvisor_headers["RateLimit-Limit"])
  assert.is_nil(ngx.header["RateLimit-Limit"])
end)

runner:then_('^header filter copies buffered header "([^"]+)" with value "([^"]+)"$', function(_, key, value)
  assert.equals(value, ngx.header[key])
end)

runner:then_("^throttle delay sleep is ([%d%.]+) seconds$", function(_, expected)
  assert.equals(tonumber(expected), ngx.sleep_calls[#ngx.sleep_calls])
end)

runner:then_('^one decision metric is emitted for action "([^"]+)" and policy "([^"]+)"$', function(ctx, action, policy)
  local found = nil
  for _, call in ipairs(ctx.metric_calls) do
    if call.metric_name == "fairvisor_decisions_total" then
      found = call
      break
    end
  end
  assert.is_not_nil(found, "fairvisor_decisions_total metric not found in " .. #ctx.metric_calls .. " calls")
  assert.equals(action, found.action)
  assert.equals(policy, found.policy_id)
end)

runner:then_('^retry after bucket metric is emitted for bucket "([^"]+)"$', function(ctx, bucket)
  local found = false
  for _, call in ipairs(ctx.metric_calls) do
    if call.metric_name == "fairvisor_retry_after_bucket_total" and call.bucket == bucket then
      found = true
      break
    end
  end
  assert.is_true(found)
end)

runner:then_("^legacy fairvisor decisions metric is not emitted$", function(ctx)
  for _, call in ipairs(ctx.metric_calls) do
    assert.not_equals("fairvisor_decision_api_decisions_total", call.metric_name)
  end
end)

runner:then_("^both retry after headers are equal$", function(ctx)
  assert.equals(ctx.first_retry_after, ctx.second_retry_after)
end)

runner:then_("^retry after headers are different$", function(ctx)
  assert.not_equals(ctx.first_retry_after, ctx.second_retry_after)
end)

runner:then_("^retry after jitter is stable per client and diversified across clients$", function(ctx)
  local unique_values = {}

  for _, sample in ipairs(ctx.retry_after_samples or {}) do
    assert.equals(sample.first, sample.second, "retry-after should be deterministic for client " .. sample.client_ip)
    unique_values[sample.first] = true
  end

  local unique_count = 0
  for _ in pairs(unique_values) do
    unique_count = unique_count + 1
  end
  assert.is_true(unique_count >= 2, "expected at least 2 retry-after values across clients")
end)

runner:then_("^shadow mode log entry is emitted$", function(_)
  local found = false
  for _, entry in ipairs(ngx.log_calls) do
    for _, part in ipairs(entry.args) do
      if type(part) == "string" and part:find("mode=shadow", 1, true) then
        found = true
      end
    end
  end

  assert.is_true(found)
end)

runner:then_("^the bundle and context were passed to rule engine$", function(ctx)
  assert.equals(ctx.bundle, ctx.last_bundle)
  assert.is_not_nil(ctx.last_request_context)
end)

runner:then_("^the test cleanup restores globals$", function(ctx)
  if ctx.original_random then
    math.random = ctx.original_random
  end

  os.getenv = ctx.original_getenv
end)

runner:feature_file_relative("features/decision_api.feature")
