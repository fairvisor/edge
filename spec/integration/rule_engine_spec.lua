package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")
local mock_bundle = require("helpers.mock_bundle")

local runner = gherkin.new({ describe = describe, context = context, it = it })
local _managed_modules = {
  "fairvisor.descriptor",
  "fairvisor.token_bucket",
  "fairvisor.cost_budget",
  "fairvisor.loop_detector",
  "fairvisor.circuit_breaker",
  "fairvisor.kill_switch",
  "fairvisor.shadow_mode",
  "fairvisor.llm_limiter",
}
local _original_preload = {}

for i = 1, #_managed_modules do
  local name = _managed_modules[i]
  _original_preload[name] = package.preload[name]
end

after_each(function()
  package.loaded["fairvisor.rule_engine"] = nil
  package.loaded["fairvisor.bundle_loader"] = nil
  package.loaded["fairvisor.health"] = nil
  package.loaded["fairvisor.route_index"] = nil
  for i = 1, #_managed_modules do
    local name = _managed_modules[i]
    package.loaded[name] = nil
    package.preload[name] = _original_preload[name]
  end
end)

local function _new_policy(id, mode, rules, fallback_limit)
  return {
    id = id,
    spec = {
      mode = mode,
      rules = rules or {},
      fallback_limit = fallback_limit,
    },
  }
end

local function _setup(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.dict = env.dict
  ctx.calls = {}
  ctx.logs = {}
  ctx.results = {}

  ngx.log = function(_level, ...)
    ctx.logs[#ctx.logs + 1] = table.concat({ ... })
  end

  ctx.request_context = {
    method = "POST",
    path = "/v1/infer",
    headers = {},
    query_params = {},
    jwt_claims = {},
    _descriptors = {},
    body_hash = "abc",
  }

  ctx.matching_policy_ids = {}
  ctx.bundle = {
    kill_switches = {},
    route_index = {
      match = function(_self, _method, _path)
        ctx.calls[#ctx.calls + 1] = "route_match"
        return ctx.matching_policy_ids
      end,
    },
    policies_by_id = {},
  }

  local descriptor = {
    extract = function(limit_keys, request_context)
      ctx.calls[#ctx.calls + 1] = "descriptor_extract"
      local descriptors = {}
      local missing = {}
      for i = 1, #limit_keys do
        local key = limit_keys[i]
        if request_context._descriptors[key] ~= nil then
          descriptors[key] = tostring(request_context._descriptors[key])
        else
          missing[#missing + 1] = key
        end
      end
      return descriptors, missing
    end,
    build_composite_key = function(limit_keys, descriptors)
      local parts = {}
      for i = 1, #limit_keys do
        parts[#parts + 1] = tostring(descriptors[limit_keys[i]] or "")
      end
      return table.concat(parts, ":")
    end,
    parse_key = function(key)
      local sep = string.find(key, ":", 1, true)
      if not sep then
        return nil, nil
      end
      return string.sub(key, 1, sep - 1), string.sub(key, sep + 1)
    end,
  }

  local token_bucket = {
    build_key = function(rule_name, limit_key)
      return "tb:" .. rule_name .. ":" .. tostring(limit_key or "")
    end,
    resolve_cost = function(_config, _request_context)
      return 1
    end,
    check = function(_dict, key, _config, _cost)
      local normalized_key = string.gsub(key, "^shadow:", "")
      local rule_name = string.match(normalized_key, "^tb:([^:]+):") or ""
      ctx.calls[#ctx.calls + 1] = "tb_check:" .. rule_name
      return ctx.results[rule_name] or { allowed = true, limit = 100, remaining = 99, reset = 1 }
    end,
  }

  local loop_detector = {
    build_fingerprint = function(_method, _path, _query, _body_hash, _descriptors)
      return "fp"
    end,
    check = function(_dict, _cfg, _key, _now)
      ctx.calls[#ctx.calls + 1] = "loop_check"
      if ctx.loop_hit then
        return { detected = true, allowed = false, reason = "loop_detected", retry_after = 60 }
      end
      return { detected = false }
    end,
  }

  local circuit_breaker = {
    check = function(_dict, _cfg, _key, _cost, _now)
      ctx.calls[#ctx.calls + 1] = "circuit_check"
      return { tripped = false }
    end,
  }

  local kill_switch = {
    check = function(_switches, _descriptors, _path, _now)
      ctx.calls[#ctx.calls + 1] = "kill_switch_check"
      if ctx.kill_switch_hit then
        return { matched = true }
      end
      return { matched = false }
    end,
  }

  local shadow_mode = {
    is_shadow = function(policy)
      return policy and policy.spec and policy.spec.mode == "shadow"
    end,
    wrap = function(decision, mode)
      decision.mode = mode or "shadow"
      decision.would_reject = decision.action == "reject"
      decision.action = "allow"
      return decision
    end,
    shadow_key = function(key)
      return "shadow:" .. key
    end,
  }

  package.loaded["fairvisor.rule_engine"] = nil
  package.loaded["fairvisor.descriptor"] = nil
  package.loaded["fairvisor.token_bucket"] = nil
  package.loaded["fairvisor.cost_budget"] = nil
  package.loaded["fairvisor.loop_detector"] = nil
  package.loaded["fairvisor.circuit_breaker"] = nil
  package.loaded["fairvisor.kill_switch"] = nil
  package.loaded["fairvisor.shadow_mode"] = nil
  package.loaded["fairvisor.llm_limiter"] = nil

  package.preload["fairvisor.descriptor"] = function() return descriptor end
  package.preload["fairvisor.token_bucket"] = function() return token_bucket end
  package.preload["fairvisor.cost_budget"] = function() return {
    build_key = function(rule_name, limit_key) return "cb:" .. rule_name .. ":" .. tostring(limit_key or "") end,
    resolve_cost = function() return 1 end,
    check = function() return { allowed = true } end,
  } end
  package.preload["fairvisor.loop_detector"] = function() return loop_detector end
  package.preload["fairvisor.circuit_breaker"] = function() return circuit_breaker end
  package.preload["fairvisor.kill_switch"] = function() return kill_switch end
  package.preload["fairvisor.shadow_mode"] = function() return shadow_mode end
  package.preload["fairvisor.llm_limiter"] = function() return { check = function() return { allowed = true } end } end

  ctx.engine = require("fairvisor.rule_engine")
  ctx.engine.init({ dict = ctx.dict })
end

runner:given("^the rule engine integration harness is reset$", function(ctx)
  _setup(ctx)
end)

local function _setup_full_chain(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.dict = env.dict
  ctx.time = env.time
  for i = 1, #_managed_modules do
    package.loaded[_managed_modules[i]] = nil
    package.preload[_managed_modules[i]] = nil
  end
  package.loaded["fairvisor.rule_engine"] = nil
  package.loaded["fairvisor.bundle_loader"] = nil
  package.loaded["fairvisor.health"] = nil
  package.loaded["fairvisor.route_index"] = nil

  local loader = require("fairvisor.bundle_loader")
  local health = require("fairvisor.health")
  ctx.loader = loader
  ctx.health = health
  ctx.engine = require("fairvisor.rule_engine")
  ctx.engine.init({ dict = ctx.dict })
end

runner:given("^the full chain integration is reset with real bundle_loader and token_bucket$", function(ctx)
  _setup_full_chain(ctx)
end)

runner:given("^a real bundle with token_bucket burst (%d+) is loaded and applied$", function(ctx, burst)
  local bundle = mock_bundle.new_bundle({
    bundle_version = 100,
    policies = {
      {
        id = "p1",
        spec = {
          selector = { pathPrefix = "/v1/", methods = { "GET", "POST" } },
          mode = "enforce",
          rules = {
            {
              name = "r1",
              limit_keys = { "jwt:org_id" },
              match = { ["jwt:plan"] = "pro" },
              algorithm = "token_bucket",
              algorithm_config = { tokens_per_second = 1, burst = tonumber(burst) },
            },
          },
        },
      },
    },
  })
  local payload = mock_bundle.encode(bundle)
  local compiled, err = ctx.loader.load_from_string(payload, nil, nil)
  assert.is_table(compiled, tostring(err))
  local ok, apply_err = ctx.loader.apply(compiled)
  assert.is_true(ok, tostring(apply_err))
  ctx.bundle = ctx.loader.get_current()
end)

runner:given("^a real bundle with kill_switch matching org%-1 is loaded and applied$", function(ctx)
  local bundle = mock_bundle.new_bundle({
    bundle_version = 101,
    kill_switches = {
      { scope_key = "jwt:org_id", scope_value = "org-1" },
    },
    policies = {
      {
        id = "p1",
        spec = {
          selector = { pathPrefix = "/v1/", methods = { "GET", "POST" } },
          mode = "enforce",
          rules = {},
        },
      },
    },
  })
  local payload = mock_bundle.encode(bundle)
  local compiled, err = ctx.loader.load_from_string(payload, nil, nil)
  assert.is_table(compiled, tostring(err))
  local ok, apply_err = ctx.loader.apply(compiled)
  assert.is_true(ok, tostring(apply_err))
  ctx.bundle = ctx.loader.get_current()
end)

runner:given("^request context is path /v1/chat with jwt org_id org%-1 and plan pro$", function(ctx)
  ctx.request_context = {
    method = "POST",
    path = "/v1/chat",
    headers = {},
    query_params = {},
    jwt_claims = { org_id = "org-1", plan = "pro" },
    _descriptors = {},
  }
end)

runner:given("^request context is path /v1/chat with jwt org_id org%-1$", function(ctx)
  ctx.request_context = {
    method = "POST",
    path = "/v1/chat",
    headers = {},
    query_params = {},
    jwt_claims = { org_id = "org-1" },
    _descriptors = { ["jwt:org_id"] = "org-1" },
  }
end)

runner:given("^request context is path /v1/chat with jwt org_id org%-1 and no precomputed descriptors$", function(ctx)
  ctx.request_context = {
    method = "POST",
    path = "/v1/chat",
    headers = {},
    query_params = {},
    jwt_claims = { org_id = "org-1" },
  }
end)

runner:when("^I evaluate the request (%d+) times$", function(ctx, n)
  ctx.decisions = {}
  for i = 1, tonumber(n) do
    ctx.decisions[i] = ctx.engine.evaluate(ctx.request_context, ctx.bundle)
  end
end)

runner:then_("^the first two evaluations are allow and the third is reject$", function(ctx)
  assert.equals("allow", ctx.decisions[1].action)
  assert.equals("allow", ctx.decisions[2].action)
  assert.equals("reject", ctx.decisions[3].action)
end)

runner:then_("^integration decision is reject with reason kill_switch$", function(ctx)
  assert.equals("reject", ctx.decision.action)
  assert.equals("kill_switch", ctx.decision.reason)
end)

runner:given("^fixture RE%-007 shadow policy would reject$", function(ctx)
  ctx.matching_policy_ids = { "p_shadow" }
  ctx.request_context._descriptors["jwt:org_id"] = "org-s"
  ctx.bundle.policies_by_id.p_shadow = _new_policy("p_shadow", "shadow", {
    {
      name = "shadow_rule",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
    },
  })
  ctx.results.shadow_rule = { allowed = false, reason = "rate_limited", limit = 10, remaining = 0, retry_after = 1 }
end)

runner:given("^fixture RE%-008 two policies second rejects$", function(ctx)
  ctx.matching_policy_ids = { "p1", "p2" }
  ctx.request_context._descriptors["jwt:org_id"] = "org-a"
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "p1_ok",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
    },
  })
  ctx.bundle.policies_by_id.p2 = _new_policy("p2", "enforce", {
    {
      name = "p2_deny",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
    },
  })
  ctx.results.p1_ok = { allowed = true, limit = 10, remaining = 9, reset = 1 }
  ctx.results.p2_deny = { allowed = false, reason = "rate_limited", limit = 10, remaining = 0, retry_after = 1 }
end)

runner:given("^fixture RE%-009 missing limit key fail%-open$", function(ctx)
  ctx.matching_policy_ids = { "p1" }
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "needs_org",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
    },
  })
end)

runner:given("^fixture kill switch takes precedence$", function(ctx)
  ctx.kill_switch_hit = true
  ctx.matching_policy_ids = { "p1" }
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "rule1",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
    },
  })
end)

runner:given("^fixture loop check happens before circuit and rules$", function(ctx)
  ctx.matching_policy_ids = { "p1" }
  ctx.loop_hit = true
  ctx.request_context._descriptors["jwt:org_id"] = "org-l"
  ctx.bundle.policies_by_id.p1 = _new_policy("p1", "enforce", {
    {
      name = "rule1",
      algorithm = "token_bucket",
      limit_keys = { "jwt:org_id" },
    },
  })
  ctx.bundle.policies_by_id.p1.spec.loop_detection = { enabled = true }
  ctx.bundle.policies_by_id.p1.spec.circuit_breaker = { enabled = true }
end)

runner:when("^I run rule engine evaluation$", function(ctx)
  ctx.decision = ctx.engine.evaluate(ctx.request_context, ctx.bundle)
end)

runner:then_("^integration decision is allow shadow would_reject true$", function(ctx)
  assert.equals("allow", ctx.decision.action)
  assert.equals("shadow", ctx.decision.mode)
  assert.is_true(ctx.decision.would_reject)
end)

runner:then_("^integration decision is reject from policy \"([^\"]+)\"$", function(ctx, policy_id)
  assert.equals("reject", ctx.decision.action)
  assert.equals(policy_id, ctx.decision.policy_id)
end)

runner:then_("^integration decision is allow all rules passed$", function(ctx)
  assert.equals("allow", ctx.decision.action)
  assert.equals("all_rules_passed", ctx.decision.reason)
end)

runner:then_("^missing descriptor log was emitted$", function(ctx)
  local found = false
  for i = 1, #ctx.logs do
    if string.find(ctx.logs[i], "descriptor_missing", 1, true) then
      found = true
      break
    end
  end
  assert.is_true(found)
end)

runner:then_("^kill switch short%-circuited route evaluation$", function(ctx)
  assert.equals("reject", ctx.decision.action)
  assert.equals("kill_switch", ctx.decision.reason)
  local saw_kill_switch = false
  for i = 1, #ctx.calls do
    if ctx.calls[i] == "kill_switch_check" then
      saw_kill_switch = true
    end
    assert.not_equals("route_match", ctx.calls[i])
  end
  assert.is_true(saw_kill_switch)
end)

runner:then_("^loop short%-circuited circuit and limiter checks$", function(ctx)
  assert.equals("reject", ctx.decision.action)
  local saw_loop = false
  for i = 1, #ctx.calls do
    if ctx.calls[i] == "loop_check" then
      saw_loop = true
    end
    assert.not_equals("circuit_check", ctx.calls[i])
    assert.is_nil(string.match(ctx.calls[i], "^tb_check:"))
  end
  assert.is_true(saw_loop)
end)

runner:feature_file_relative("features/rule_engine.feature")
