local ok_cjson_safe, cjson_safe = pcall(require, "cjson.safe")
local ok_cjson, cjson = false, nil
if not ok_cjson_safe then
  ok_cjson, cjson = pcall(require, "cjson")
end
local utils = require("fairvisor.utils")
local json_fallback = not ok_cjson_safe and not ok_cjson and utils.get_json() or nil

local _M = {}

local function _json_encode(value)
  if ok_cjson_safe then
    return cjson_safe.encode(value)
  end
  if ok_cjson then
    local ok, s = pcall(cjson.encode, value)
    if ok then
      return s
    end
  end
  if json_fallback then
    local s, _ = json_fallback.encode(value)
    return s
  end
  return nil
end

local function _deep_copy(value)
  if type(value) ~= "table" then
    return value
  end

  local copied = {}
  for k, v in pairs(value) do
    copied[k] = _deep_copy(v)
  end

  return copied
end

local function _base_bundle()
  return {
    bundle_version = 1,
    issued_at = "2026-02-03T10:00:00Z",
    expires_at = "2030-02-04T10:00:00Z",
    policies = {
      {
        id = "policy-api-rate",
        spec = {
          selector = {
            pathPrefix = "/v1/",
            methods = { "GET", "POST" },
          },
          mode = "enforce",
          rules = {
            {
              name = "tier-rate-limit",
              limit_keys = { "jwt:org_id" },
              match = {
                ["jwt:plan"] = "pro",
              },
              algorithm = "token_bucket",
              algorithm_config = {
                tokens_per_second = 100,
                burst = 200,
              },
            },
          },
        },
      },
    },
    kill_switches = {},
    defaults = {
      default_cost = 1,
    },
  }
end

function _M.new_bundle(overrides)
  local bundle = _base_bundle()
  if type(overrides) == "table" then
    for key, value in pairs(overrides) do
      bundle[key] = _deep_copy(value)
    end
  end
  return bundle
end

function _M.encode(bundle)
  return _json_encode(bundle)
end

function _M.sign(payload, key)
  local raw_signature = ngx.hmac_sha256(key, payload)
  return ngx.encode_base64(raw_signature) .. "\n" .. payload
end

function _M.invalid_signature_payload(payload, key)
  local signed = _M.sign(payload, key)
  return signed .. " "
end

return _M
