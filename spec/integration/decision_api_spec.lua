package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local decision_api = require("fairvisor.decision_api")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local runner = gherkin.new({ describe = describe, context = context, it = it })

runner:given("^the integration nginx environment is reset$", function(ctx)
  mock_ngx.setup_ngx()

  local headers = {}
  local args = {}

  ngx.req = {
    get_headers = function()
      return headers
    end,
    get_uri_args = function()
      return args
    end,
  }

  ngx.var = {
    request_method = "GET",
    uri = "/v1/decision",
    remote_addr = "127.0.0.1",
  }

  ngx.header = {}
  ngx.ctx = {}

  ngx.decode_base64 = function(input)
    if input == "eyJzdWIiOiJjdXN0b21lci0xIn0=" then
      return '{"sub":"customer-1"}'
    end

    return nil
  end

  ngx.exit_calls = {}
  ngx.exit = function(code)
    ngx.exit_calls[#ngx.exit_calls + 1] = code
    return code
  end

  ngx.sleep = function()
  end

  ngx.log_calls = {}
  ngx.log = function(level, ...)
    ngx.log_calls[#ngx.log_calls + 1] = { level = level, args = { ... } }
  end

  ctx.decision = nil
  ctx.metric_calls = {}

  ctx.bundle_loader = {
    get_current = function()
      return { id = "bundle-int" }
    end,
  }

  ctx.rule_engine = {
    evaluate = function(_request_context, _bundle)
      return ctx.decision
    end,
  }

  ctx.health = {
    inc = function(_, metric_name, labels)
      ctx.metric_calls[#ctx.metric_calls + 1] = {
        metric_name = metric_name,
        action = labels and labels.action or nil,
        policy_id = labels and labels.policy_id or nil,
        bucket = labels and labels.bucket or nil,
      }
    end,
  }

  ctx.original_getenv = os.getenv
end)

runner:given('^integration mode is "([^"]+)" with retry jitter "([^"]+)"$', function(ctx, mode, _jitter)
  os.getenv = function(key)
    if key == "FAIRVISOR_MODE" then return mode end
    return nil
  end
  local ok, err = decision_api.init({
    bundle_loader = ctx.bundle_loader,
    rule_engine = ctx.rule_engine,
    health = ctx.health,
  })
  assert.is_true(ok)
  assert.is_nil(err)
end)

runner:given('^integration decision is allow with limit "([^"]+)" and remaining "([^"]+)"$', function(ctx, limit, remaining)
  ctx.decision = {
    action = "allow",
    policy_id = "policy-da-allow",
    headers = {
      ["RateLimit-Limit"] = limit,
      ["RateLimit-Remaining"] = remaining,
      ["RateLimit-Reset"] = "1",
    },
  }
end)

runner:given('^integration decision is reject reason "([^"]+)" retry_after (%d+)$', function(ctx, reason, retry_after)
  ctx.decision = {
    action = "reject",
    reason = reason,
    policy_id = "policy-da-reject",
    retry_after = tonumber(retry_after),
    headers = {
      ["RateLimit-Limit"] = "200",
      ["RateLimit-Remaining"] = "0",
      ["RateLimit-Reset"] = tostring(retry_after),
    },
  }
end)

runner:given("^integration decision is shadow allow with would reject metadata$", function(ctx)
  ctx.decision = {
    action = "allow",
    mode = "shadow",
    policy_id = "policy-da-shadow",
    headers = {
      ["RateLimit-Limit"] = "200",
      ["RateLimit-Remaining"] = "199",
      ["RateLimit-Reset"] = "1",
      ["X-Fairvisor-Would-Reject"] = "true",
    },
  }
end)

runner:when("^I run integration access handler$", function(ctx)
  ctx.access_result = decision_api.access_handler()
end)

runner:when("^I run integration header filter handler$", function(ctx)
  ctx.header_filter_result = decision_api.header_filter_handler()
end)

runner:then_("^integration response is allow with status untouched$", function(_)
  assert.equals(0, #ngx.exit_calls)
  assert.is_nil(ngx.status)
end)

runner:then_("^integration response is rejected with status (%d+)$", function(_, status)
  assert.equals(tonumber(status), ngx.status)
  assert.equals(tonumber(status), ngx.exit_calls[#ngx.exit_calls])
end)

runner:then_('^integration header "([^"]+)" equals "([^"]+)"$', function(_, header_name, expected)
  assert.equals(expected, tostring(ngx.header[header_name]))
end)

runner:then_('^integration header "([^"]+)" is between (%d+) and (%d+)$', function(_, header_name, min_val, max_val)
  local v = tonumber(ngx.header[header_name])
  assert.is_true(v >= tonumber(min_val) and v <= tonumber(max_val),
    "expected " .. tostring(header_name) .. " in [" .. min_val .. "," .. max_val .. "], got " .. tostring(v))
end)

runner:then_('^integration metric action is "([^"]+)"$', function(ctx, action)
  local found = false
  for i = 1, #ctx.metric_calls do
    local metric = ctx.metric_calls[i]
    if metric.metric_name == "fairvisor_decisions_total" and metric.action == action then
      found = true
      break
    end
  end
  assert.is_true(found)
end)

runner:then_('^integration retry after bucket metric is "([^"]+)"$', function(ctx, bucket)
  local found = false
  for i = 1, #ctx.metric_calls do
    local metric = ctx.metric_calls[i]
    if metric.metric_name == "fairvisor_retry_after_bucket_total" and metric.bucket == bucket then
      found = true
      break
    end
  end
  assert.is_true(found)
end)

runner:then_("^integration logs contain shadow mode$", function(_)
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

runner:then_("^integration cleanup restores getenv$", function(ctx)
  os.getenv = ctx.original_getenv
end)

runner:feature_file_relative("features/decision_api.feature")
