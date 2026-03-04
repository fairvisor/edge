local ceil = math.ceil
local max = math.max
local min = math.min
local pairs = pairs
local pcall = pcall
local string_byte = string.byte
local string_find = string.find
local string_format = string.format
local string_gmatch = string.gmatch
local string_gsub = string.gsub
local string_match = string.match
local string_lower = string.lower
local string_sub = string.sub
local table_concat = table.concat
local table_sort = table.sort
local tonumber = tonumber
local tostring = tostring
local type = type
local os_time = os.time

local utils = require("fairvisor.utils")
local json_lib = utils.get_json()

local _M = {}

local _deps = {
  bundle_loader = nil,
  rule_engine = nil,
  health = nil,
}

local _config = {
  mode = "decision_service",
  retry_jitter_mode = "deterministic",
  retry_jitter_max_ratio = 0.5,
  retry_after_max = nil,
  retry_jitter_salt = "fairvisor-retry-jitter",
  debug_session_secret = nil,
  debug_session_ttl_seconds = 900,
}

local HTTP_SERVICE_UNAVAILABLE = 503
local HTTP_TOO_MANY_REQUESTS = 429
local HTTP_NO_CONTENT = 204
local HTTP_FORBIDDEN = 403
local HTTP_NOT_FOUND = 404
local DEBUG_COOKIE_NAME = "fv_dbg"
local MAX_THROTTLE_DELAY_MS = 30000
local RETRY_JITTER_SEED_VERSION = "retry_jitter:v1"
local RETRY_AFTER_BUCKETS = {
  { upper = 1, label = "le_1" },
  { upper = 5, label = "le_5" },
  { upper = 10, label = "le_10" },
  { upper = 30, label = "le_30" },
  { upper = 60, label = "le_60" },
  { upper = 300, label = "le_300" },
  { upper = 900, label = "le_900" },
  { upper = 3600, label = "le_3600" },
}

local function _log_err(...)
  if ngx and ngx.log then ngx.log(ngx.ERR, ...) end
end
local function _log_warn(...)
  if ngx and ngx.log then ngx.log(ngx.WARN, ...) end
end
local function _log_info(...)
  if ngx and ngx.log then ngx.log(ngx.INFO, ...) end
end

local function _inc_handler_metric(name, value, labels)
  local health = _deps.health
  if not health or type(health.inc) ~= "function" then
    return
  end

  pcall(health.inc, health, name, labels or {}, value)
end

-- Fallback when no cjson or decode failed: flat keys only. Nested objects/arrays return nil.
local function _decode_json_fallback(input)
  if type(input) ~= "string" then
    return nil
  end

  local body = string_match(input, "^%s*{%s*(.-)%s*}%s*$")
  if not body then
    return nil
  end

  if body == "" then
    return {}
  end

  local result = {}
  for key, raw_value in string_gmatch(body, '"([^"]+)"%s*:%s*([^,]+)') do
    local value = raw_value
    if string_match(value, "%s*[{[]%s*") then
      return nil
    end
    local string_value = string_match(value, '^%s*"(.-)"%s*$')
    if string_value ~= nil then
      result[key] = string_value
    else
      local number_value = tonumber(value)
      if number_value ~= nil then
        result[key] = number_value
      elseif string_match(value, "^%s*true%s*$") then
        result[key] = true
      elseif string_match(value, "^%s*false%s*$") then
        result[key] = false
      elseif string_match(value, "^%s*null%s*$") then
        result[key] = nil
      else
        return nil
      end
    end
  end

  return result
end

local function _is_decision_service_mode()
  return _config.mode == "decision_service"
end

local function _stable_jitter_ratio(seed)
  if type(seed) ~= "string" or seed == "" then
    return 0
  end

  local hash = 0
  for i = 1, #seed do
    hash = (hash * 131 + string_byte(seed, i)) % 1000003
  end

  return hash / 1000003
end

local function _stable_identity_hash(value)
  if type(value) ~= "string" or value == "" then
    return "00000000"
  end

  local salted_value = tostring(_config.retry_jitter_salt or "") .. "|" .. value
  if ngx and type(ngx.hmac_sha256) == "function" then
    local ok, digest = pcall(ngx.hmac_sha256, tostring(_config.retry_jitter_salt or ""), value)
    if ok and type(digest) == "string" and #digest >= 8 then
      local first4 = string_byte(digest, 1) * 16777216
        + string_byte(digest, 2) * 65536
        + string_byte(digest, 3) * 256
        + string_byte(digest, 4)
      return string_format("%08x", first4)
    end
  end

  if ngx and type(ngx.sha1_bin) == "function" then
    local ok, digest = pcall(ngx.sha1_bin, salted_value)
    if ok and type(digest) == "string" and #digest >= 8 then
      local first4 = string_byte(digest, 1) * 16777216
        + string_byte(digest, 2) * 65536
        + string_byte(digest, 3) * 256
        + string_byte(digest, 4)
      return string_format("%08x", first4)
    end
  end

  local hash = 0
  for i = 1, #salted_value do
    hash = (hash * 131 + string_byte(salted_value, i)) % 2147483629
  end

  return string_format("%08x", hash)
end

-- Fixed deterministic jitter: same seed -> same value; no env configuration.
local function _compute_retry_after_with_jitter(base, seed, cap_to_base)
  local base_number = tonumber(base)
  if not base_number or base_number <= 0 then
    return nil
  end

  local jitter_ratio = _stable_jitter_ratio(seed or "")
  jitter_ratio = max(0, min(1, jitter_ratio))
  local jitter = jitter_ratio * base_number * (_config.retry_jitter_max_ratio or 0.5)
  local retry_after = ceil(base_number + jitter)
  if cap_to_base then
    -- Keep jitter while guaranteeing Retry-After never exceeds the strict window boundary.
    retry_after = ceil(base_number - jitter)
  end
  if retry_after < 1 then
    retry_after = 1
  end
  return retry_after
end

local function _build_jitter_identity(request_context)
  if type(request_context) ~= "table" then
    return ""
  end

  local claims = request_context.jwt_claims
  local subject = claims and (claims.sub or claims.user_id or claims.uid)

  local raw_identity = tostring(subject or "") .. "|"
    .. tostring(request_context.ip_address or "") .. "|"
    .. tostring(request_context.path or "")

  return _stable_identity_hash(raw_identity)
end

-- Jitter seed contract (v1):
-- retry_jitter:v1|policy_id|rule_name|reason|retry_after|identity_hash
local function _build_retry_jitter_seed(decision, request_context)
  return RETRY_JITTER_SEED_VERSION .. "|"
    .. tostring(decision.policy_id or "") .. "|"
    .. tostring(decision.rule_name or "") .. "|"
    .. tostring(decision.reason or "") .. "|"
    .. tostring(decision.retry_after or "") .. "|"
    .. _build_jitter_identity(request_context)
end

local function _retry_after_bucket_label(retry_after)
  local retry_after_num = tonumber(retry_after)
  if not retry_after_num or retry_after_num <= 0 then
    return nil
  end

  for i = 1, #RETRY_AFTER_BUCKETS do
    local bucket = RETRY_AFTER_BUCKETS[i]
    if retry_after_num <= bucket.upper then
      return bucket.label
    end
  end

  return "gt_3600"
end

local function _set_response_headers(headers)
  if type(headers) ~= "table" then
    return
  end

  for key, value in pairs(headers) do
    if value ~= nil then
      ngx.header[key] = value
    end
  end
end

local function _maybe_emit_metric(decision)
  local health = _deps.health
  if not health or type(health.inc) ~= "function" then
    return
  end

  -- Pass a fresh table so health.inc does not hold a reference to shared _metric_tags.
  local tags = {
    action = decision.action or "unknown",
    policy_id = decision.policy_id or "none",
  }
  local ok, err = pcall(health.inc, health, "fairvisor_decisions_total", tags)
  if not ok then
    _log_err("_maybe_emit_metric err=", err)
  end
end

local function _maybe_emit_ratelimit_remaining_metric(decision, request_context)
  local health = _deps.health
  if not health or type(health.set) ~= "function" then
    return
  end

  local headers = decision and decision.headers
  if type(headers) ~= "table" then
    return
  end

  local remaining = tonumber(headers["RateLimit-Remaining"])
  if remaining == nil then
    return
  end

  local ok, err = pcall(health.set, health, "fairvisor_ratelimit_remaining", {
    window = "request",
    policy = tostring(decision and decision.policy_id or "none"),
    route = tostring(request_context and request_context.path or ""),
  }, remaining)
  if not ok then
    _log_err("_maybe_emit_ratelimit_remaining_metric err=", err)
  end
end

local function _maybe_emit_retry_after_metric(retry_after)
  local health = _deps.health
  if not health or type(health.inc) ~= "function" then
    return
  end

  local bucket = _retry_after_bucket_label(retry_after)
  if not bucket then
    return
  end

  local ok, err = pcall(health.inc, health, "fairvisor_retry_after_bucket_total", {
    bucket = bucket,
  })
  if not ok then
    _log_err("_maybe_emit_retry_after_metric err=", err)
  end
end

local function _safe_var(name)
  if not ngx or not ngx.var then
    return nil
  end

  local ok, value = pcall(function()
    return ngx.var[name]
  end)
  if not ok then
    return nil
  end

  return value
end

local function _base64url_encode(raw)
  if type(raw) ~= "string" then
    return nil
  end

  local encoded = utils.encode_base64(raw)
  if not encoded then
    local hex = {}
    for i = 1, #raw do
      hex[#hex + 1] = string_format("%02x", string_byte(raw, i))
    end
    return table_concat(hex, "")
  end

  encoded = string_gsub(encoded, "+", "-")
  encoded = string_gsub(encoded, "/", "_")
  encoded = string_gsub(encoded, "=+$", "")
  return encoded
end

local function _read_cookie(name)
  local cookie_header = _safe_var("http_cookie")
  if type(cookie_header) ~= "string" or cookie_header == "" then
    return nil
  end

  for part in string_gmatch(cookie_header, "([^;]+)") do
    local k, v = string_match(part, "^%s*([^=]+)%s*=%s*(.-)%s*$")
    if k == name then
      return v
    end
  end

  return nil
end

local function _sign_debug_payload(payload)
  if type(payload) ~= "string" or payload == "" then
    return nil
  end
  if type(_config.debug_session_secret) ~= "string" or _config.debug_session_secret == "" then
    return nil
  end

  local digest = nil
  if ngx and type(ngx.hmac_sha256) == "function" then
    local ok, hmac_digest = pcall(ngx.hmac_sha256, _config.debug_session_secret, payload)
    if ok and type(hmac_digest) == "string" then
      digest = hmac_digest
    end
  end

  if digest == nil and ngx and type(ngx.sha1_bin) == "function" then
    local ok, sha_digest = pcall(ngx.sha1_bin, _config.debug_session_secret .. "|" .. payload)
    if ok and type(sha_digest) == "string" then
      digest = sha_digest
    end
  end

  if digest == nil then
    return nil
  end

  return _base64url_encode(digest)
end

local function _build_debug_cookie(expire_at)
  local payload = tostring(expire_at)
  local signature = _sign_debug_payload(payload)
  if signature == nil then
    return nil
  end
  return payload .. "." .. signature
end

local function _is_debug_cookie_valid()
  local token = _read_cookie(DEBUG_COOKIE_NAME)
  if type(token) ~= "string" or token == "" then
    return false
  end

  local expire_s, signature = string_match(token, "^(%d+)%.([A-Za-z0-9_-]+)$")
  if expire_s == nil or signature == nil then
    return false
  end

  local expire_at = tonumber(expire_s)
  if not expire_at or expire_at <= 0 then
    return false
  end
  if expire_at <= os_time() then
    return false
  end

  local expected = _sign_debug_payload(expire_s)
  if expected == nil then
    return false
  end

  return utils.constant_time_equals(expected, signature)
end

local function _set_debug_cookie(expire_at)
  local value = _build_debug_cookie(expire_at)
  if value == nil then
    return nil
  end

  ngx.header["Set-Cookie"] =
    DEBUG_COOKIE_NAME .. "=" .. value .. "; Path=/; Max-Age=" .. tostring(_config.debug_session_ttl_seconds)
    .. "; HttpOnly; Secure; SameSite=Strict"
  return true
end

local function _clear_debug_cookie()
  ngx.header["Set-Cookie"] =
    DEBUG_COOKIE_NAME .. "=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict"
end

local function _debug_headers_enabled_for_request()
  return _is_debug_cookie_valid()
end

local function _first_header(headers, canonical)
  if not headers then
    return nil
  end

  local direct = headers[canonical]
  if direct ~= nil then
    return direct
  end

  return headers[string_lower(canonical)]
end

local function _normalize_request_host(host)
  if type(host) ~= "string" then
    return nil
  end

  local trimmed = string_match(host, "^%s*(.-)%s*$")
  if trimmed == nil or trimmed == "" then
    return nil
  end

  local normalized = string_lower(trimmed)
  local without_port = string_match(normalized, "^([^:]+):%d+$")
  if without_port and without_port ~= "" then
    normalized = without_port
  end

  normalized = string_gsub(normalized, "%.$", "")
  if normalized == "" then
    return nil
  end

  return normalized
end

function _M.decode_jwt_payload(auth_header)
  if type(auth_header) ~= "string" then
    return nil
  end

  if string_sub(auth_header, 1, 7) ~= "Bearer " then
    return nil
  end

  local token = string_sub(auth_header, 8)
  local first_dot = string_find(token, ".", 1, true)
  if not first_dot then
    return nil
  end

  local second_dot = string_find(token, ".", first_dot + 1, true)
  if not second_dot then
    return nil
  end

  if string_find(token, ".", second_dot + 1, true) then
    return nil
  end

  local payload_b64 = string_sub(token, first_dot + 1, second_dot - 1)
  local payload_json = utils.base64url_decode(payload_b64)
  if not payload_json then
    return nil
  end

  if not json_lib then
    return _decode_json_fallback(payload_json)
  end

  local decoded, _ = json_lib.decode(payload_json)
  if decoded then
    return decoded
  end
  return _decode_json_fallback(payload_json)
end

-- Normalize header name: lowercase and hyphen to underscore (OpenResty get_headers() style).
local function _header_key_underscore(name)
  if type(name) ~= "string" then
    return name
  end
  return string_gsub(string_lower(name), "-", "_")
end

-- Canonical form with hyphens (as in limit_keys, e.g. "x-e2e-key").
local function _header_key_hyphen(name)
  if type(name) ~= "string" then
    return name
  end
  return string_gsub(string_lower(name), "_", "-")
end

local function _normalize_boolish(value)
  if value == nil then
    return nil
  end
  if value == true then
    return "true"
  end
  if value == false then
    return "false"
  end
  local text = string_lower(tostring(value))
  if text == "1" or text == "true" or text == "yes" then
    return "true"
  end
  if text == "0" or text == "false" or text == "no" then
    return "false"
  end
  return nil
end

function _M.build_request_context(bundle)
  local raw_headers = ngx.req.get_headers()
  -- Build a copy with both underscore and hyphen forms so descriptor extract finds headers
  -- regardless of how get_headers() normalizes (e.g. X-E2E-Key -> x_e2e_key or x-e2e-key).
  local headers = {}
  if type(raw_headers) == "table" then
    for k, v in pairs(raw_headers) do
      if type(k) == "string" then
        headers[k] = v
        headers[_header_key_underscore(k)] = v
        headers[_header_key_hyphen(k)] = v
      end
    end
  end

  local decision_service_mode = _is_decision_service_mode()

  local method = ngx.var.request_method
  local path = ngx.var.uri
  local host = ngx.var.host

  if decision_service_mode then
    method = _first_header(headers, "X-Original-Method") or method
    path = _first_header(headers, "X-Original-URI") or path
    host = _first_header(headers, "X-Original-Host") or host
  end

  local auth_header = _first_header(headers, "Authorization")
  local descriptor_hints = bundle and bundle.descriptor_hints or {}
  local needs_user_agent = true
  if bundle ~= nil then
    needs_user_agent = descriptor_hints and descriptor_hints.needs_user_agent == true
  end

  return {
    method = method,
    path = path,
    host = _normalize_request_host(host),
    headers = headers,
    query_params = ngx.req.get_uri_args(),
    jwt_claims = _M.decode_jwt_payload(auth_header),
    ip_address = ngx.var.remote_addr,
    ip_country = _safe_var("geoip2_data_country_iso_code") or _first_header(headers, "X-Country-Code"),
    ip_asn = _safe_var("asn") or _first_header(headers, "X-ASN"),
    ip_type = _safe_var("fairvisor_asn_type") or _first_header(headers, "X-ASN-Type"),
    ip_tor = _normalize_boolish(_first_header(headers, "X-Tor-Exit")) or _normalize_boolish(_safe_var("is_tor_exit")),
    user_agent = needs_user_agent and _first_header(headers, "User-Agent") or nil,
  }
end

local function _prepare_reject_headers(decision_headers, decision, request_context)
  local headers = decision_headers or {}

  local retry_after_base = headers["Retry-After"]
  if retry_after_base == nil then
    retry_after_base = decision.retry_after
  end

  if retry_after_base ~= nil then
    local jitter_seed = _build_retry_jitter_seed(decision, request_context)
    local retry_after = _compute_retry_after_with_jitter(
      retry_after_base,
      jitter_seed,
      decision.reason == "budget_exceeded"
    )
    if retry_after then
      headers["Retry-After"] = retry_after
    end
  end

  if headers["Retry-After"] == nil then
    headers["Retry-After"] = "1"
  end

  if headers["RateLimit-Reset"] == nil then
    headers["RateLimit-Reset"] = tostring(headers["Retry-After"])
  end

  if headers["RateLimit"] == nil then
    local policy_name = decision.policy_id or "default"
    local reset = headers["RateLimit-Reset"] or "1"
    headers["RateLimit"] = '"' .. tostring(policy_name) .. '";r=0;t=' .. tostring(reset)
  end

  return headers
end

local function _decision_mode(decision)
  if type(decision) == "table" and decision.mode == "shadow" then
    return "shadow"
  end
  return "enforce"
end

local function _inject_debug_headers(headers, decision)
  if not _debug_headers_enabled_for_request() then
    return headers
  end

  headers = headers or {}
  headers["X-Fairvisor-Decision"] = tostring(decision and decision.action or "allow")
  headers["X-Fairvisor-Mode"] = _decision_mode(decision)

  local latency_us = decision and decision.latency_us
  if latency_us ~= nil then
    headers["X-Fairvisor-Latency-Us"] = tostring(latency_us)
  end

  if _is_debug_cookie_valid() and type(decision) == "table" then
    headers["X-Fairvisor-Debug-Decision"] = tostring(decision.action or "allow")
    headers["X-Fairvisor-Debug-Mode"] = _decision_mode(decision)
    headers["X-Fairvisor-Debug-Reason"] = tostring(decision.reason or "")
    headers["X-Fairvisor-Debug-Policy"] = tostring(decision.policy_id or "")
    headers["X-Fairvisor-Debug-Rule"] = tostring(decision.rule_name or "")
    headers["X-Fairvisor-Debug-Latency-Us"] = tostring(decision.latency_us or "")
    headers["X-Fairvisor-Debug-Matched-Policies"] = tostring(decision.matched_policy_count or 0)

    local descriptors = decision.debug_descriptors
    if type(descriptors) == "table" then
      local keys = {}
      for key, _ in pairs(descriptors) do
        keys[#keys + 1] = key
      end
      table_sort(keys)

      local limit = min(#keys, 16)
      for i = 1, limit do
        local key = keys[i]
        local value = tostring(descriptors[key] or "")
        if #value > 256 then
          value = string_sub(value, 1, 256)
        end
        headers["X-Fairvisor-Debug-Descriptor-" .. tostring(i) .. "-Key"] = tostring(key)
        headers["X-Fairvisor-Debug-Descriptor-" .. tostring(i) .. "-Value"] = value
      end
    end
  end

  return headers
end

function _M.init(deps)
  if type(deps) ~= "table" then
    return nil, "deps must be a table"
  end

  if type(deps.bundle_loader) ~= "table" then
    return nil, "bundle_loader dependency is required"
  end

  if type(deps.rule_engine) ~= "table" then
    return nil, "rule_engine dependency is required"
  end

  _deps.bundle_loader = deps.bundle_loader
  _deps.rule_engine = deps.rule_engine
  _deps.health = deps.health

  if not deps.health or type(deps.health.inc) ~= "function" then
    _log_warn("init health not provided or health.inc missing; decision metrics disabled")
  end

  local mode = os.getenv("FAIRVISOR_MODE")
  if mode == "reverse_proxy" then
    _config.mode = "reverse_proxy"
  else
    _config.mode = "decision_service"
  end

  _config.debug_session_secret = deps.config and deps.config.debug_session_secret or nil

  -- Retry-After jitter is fixed: deterministic with fixed salt (non-configurable).
  return true
end

function _M.access_handler()
  _log_info("access_handler entered=true")
  _inc_handler_metric("fairvisor_handler_invocations_total", 1)

  local bundle_loader = _deps.bundle_loader
  local rule_engine = _deps.rule_engine

  if not bundle_loader or type(bundle_loader.get_current) ~= "function" then
    _log_err("access_handler bundle_loader.get_current is not available")
    if _debug_headers_enabled_for_request() then
      ngx.header["X-Fairvisor-Reason"] = "service_unavailable"
    end
    ngx.status = HTTP_SERVICE_UNAVAILABLE
    return ngx.exit(HTTP_SERVICE_UNAVAILABLE)
  end

  if not rule_engine or type(rule_engine.evaluate) ~= "function" then
    _log_err("access_handler rule_engine.evaluate is not available")
    if _debug_headers_enabled_for_request() then
      ngx.header["X-Fairvisor-Reason"] = "service_unavailable"
    end
    ngx.status = HTTP_SERVICE_UNAVAILABLE
    return ngx.exit(HTTP_SERVICE_UNAVAILABLE)
  end

  local bundle = bundle_loader.get_current()
  if not bundle then
    if _debug_headers_enabled_for_request() then
      ngx.header["X-Fairvisor-Reason"] = "no_bundle_loaded"
    end
    ngx.status = HTTP_SERVICE_UNAVAILABLE
    return ngx.exit(HTTP_SERVICE_UNAVAILABLE)
  end

  local request_context = _M.build_request_context(bundle)
  local decision = rule_engine.evaluate(request_context, bundle)
  if type(decision) ~= "table" then
    _log_err("access_handler rule_engine returned invalid decision")
    if _debug_headers_enabled_for_request() then
      ngx.header["X-Fairvisor-Reason"] = "service_unavailable"
    end
    ngx.status = HTTP_SERVICE_UNAVAILABLE
    return ngx.exit(HTTP_SERVICE_UNAVAILABLE)
  end

  _maybe_emit_metric(decision)
  _maybe_emit_ratelimit_remaining_metric(decision, request_context)

  _log_info("access_handler action=", decision.action or "allow",
    " reason=", decision.reason or "",
    " policy_id=", decision.policy_id or "none",
    " latency_us=", decision.latency_us or 0)

  if decision.mode == "shadow" then
    _log_info("access_handler mode=shadow would_reject=", tostring(decision.would_reject or false))
  end

  if decision.action == "reject" then
    local reject_headers = _prepare_reject_headers(decision.headers, decision, request_context)
    _inject_debug_headers(reject_headers, decision)
    if not _debug_headers_enabled_for_request() then
      reject_headers["X-Fairvisor-Reason"] = nil
    end
    _maybe_emit_retry_after_metric(reject_headers["Retry-After"])
    _set_response_headers(reject_headers)
    ngx.status = HTTP_TOO_MANY_REQUESTS
    return ngx.exit(HTTP_TOO_MANY_REQUESTS)
  end

  if decision.action == "throttle" and decision.delay_ms then
    local delay_ms = tonumber(decision.delay_ms)
    if delay_ms and delay_ms > 0 then
      if delay_ms > MAX_THROTTLE_DELAY_MS then
        delay_ms = MAX_THROTTLE_DELAY_MS
      end
      ngx.sleep(delay_ms / 1000)
    end
  end

  if decision.headers then
    _inject_debug_headers(decision.headers, decision)
    if _is_decision_service_mode() then
      _set_response_headers(decision.headers)
    else
      ngx.ctx.fairvisor_headers = decision.headers
    end
  elseif _debug_headers_enabled_for_request() then
    local debug_headers = _inject_debug_headers({}, decision)
    if _is_decision_service_mode() then
      _set_response_headers(debug_headers)
    else
      ngx.ctx.fairvisor_headers = debug_headers
    end
  end

  return nil
end

local function _json_response(status, body)
  ngx.status = status
  ngx.header["Content-Type"] = "application/json"
  if json_lib and type(json_lib.encode) == "function" then
    local encoded, _ = json_lib.encode(body)
    if encoded == nil then
      encoded = '{"error":"json_encode_error"}'
    end
    ngx.say(encoded)
  else
    ngx.say('{"error":"serialization_unavailable"}')
  end
  return ngx.exit(status)
end

function _M.debug_session_handler()
  if type(_config.debug_session_secret) ~= "string" or _config.debug_session_secret == "" then
    return ngx.exit(HTTP_NOT_FOUND)
  end

  if ngx.req.get_method() ~= "POST" then
    return ngx.exit(405)
  end

  local headers = ngx.req.get_headers()
  local provided = headers and (headers["X-Fairvisor-Debug-Secret"] or headers["x-fairvisor-debug-secret"])
  if type(provided) ~= "string" then
    return _json_response(HTTP_FORBIDDEN, { error = "debug_secret_invalid" })
  end

  if not utils.constant_time_equals(provided, _config.debug_session_secret) then
    return _json_response(HTTP_FORBIDDEN, { error = "debug_secret_invalid" })
  end

  local expire_at = os_time() + (_config.debug_session_ttl_seconds or 900)
  if not _set_debug_cookie(expire_at) then
    return _json_response(HTTP_SERVICE_UNAVAILABLE, { error = "debug_cookie_unavailable" })
  end

  ngx.status = HTTP_NO_CONTENT
  return ngx.exit(HTTP_NO_CONTENT)
end

function _M.debug_logout_handler()
  if type(_config.debug_session_secret) ~= "string" or _config.debug_session_secret == "" then
    return ngx.exit(HTTP_NOT_FOUND)
  end

  if ngx.req.get_method() ~= "POST" then
    return ngx.exit(405)
  end

  _clear_debug_cookie()
  ngx.status = HTTP_NO_CONTENT
  return ngx.exit(HTTP_NO_CONTENT)
end

function _M.header_filter_handler()
  if not ngx.ctx or not ngx.ctx.fairvisor_headers then
    return nil
  end

  for key, value in pairs(ngx.ctx.fairvisor_headers) do
    ngx.header[key] = value
  end

  return nil
end

function _M.log_handler()
  return nil
end

return _M
