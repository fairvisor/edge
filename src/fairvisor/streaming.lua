local ceil = math.ceil
local tostring = tostring
local type = type
local ipairs = ipairs
local string_find = string.find
local string_gmatch = string.gmatch
local string_match = string.match
local string_sub = string.sub
local string_lower = string.lower
local table_concat = table.concat

local llm_limiter = require("fairvisor.llm_limiter")

local utils = require("fairvisor.utils")
local json_lib = utils.get_json()

local function _log_err(...)
  if ngx and ngx.log then ngx.log(ngx.ERR, ...) end
end
local function _log_info(...)
  if ngx and ngx.log then ngx.log(ngx.INFO, ...) end
end

local DEFAULT_BUFFER_TOKENS = 100
local DEFAULT_MAX_COMPLETION_TOKENS = 2048
local DEFAULT_LIMIT_EXCEEDED_MODE = "graceful_close"

local _M = {}

local function _starts_with(text, prefix)
  return string_sub(text, 1, #prefix) == prefix
end

local function _detect_stream_flag_from_body(body)
  if type(body) ~= "string" or body == "" then
    return false
  end

  if string_find(body, '"stream"%s*:%s*true') then
    return true
  end

  return false
end

local function _detect_stream_flag_from_headers(headers)
  if type(headers) ~= "table" then
    return false
  end

  local accept = headers["accept"] or headers["Accept"]
  if type(accept) == "string" and string_find(string_lower(accept), "text/event-stream", 1, true) then
    return true
  end

  return false
end

local function _build_usage_fragment(ctx)
  if not ctx.include_partial_usage then
    return ""
  end

  local total_tokens = (ctx.prompt_tokens or 0) + (ctx.tokens_used or 0)
  return ',"usage":{"prompt_tokens":' .. tostring(ctx.prompt_tokens or 0)
    .. ',"completion_tokens":' .. tostring(ctx.tokens_used or 0)
    .. ',"total_tokens":' .. tostring(total_tokens) .. "}"
end

local function _build_finish_sse_event(ctx)
  return 'data: {"choices":[{"delta":{},"finish_reason":"length"}]'
    .. _build_usage_fragment(ctx) .. "}\n\n"
end

local function _build_error_sse_event(ctx)
  return 'data: {"error":{"message":"max completion tokens exceeded",'
    .. '"type":"rate_limit_error","code":"completion_tokens_exceeded"}'
    .. _build_usage_fragment(ctx) .. "}\n\n"
end

local function _build_termination(ctx)
  if ctx.on_limit_exceeded == "error_chunk" then
    return _build_error_sse_event(ctx) .. "data: [DONE]\n\n"
  end

  return _build_finish_sse_event(ctx) .. "data: [DONE]\n\n"
end

local function _parse_single_event(event_str)
  local data = nil

  for line in string_gmatch(event_str, "[^\n]+") do
    if _starts_with(line, "data: ") then
      data = string_sub(line, 7)
    elseif line == "data:" then
      data = ""
    end
  end

  if data ~= nil then
    return {
      data = data,
      raw = event_str,
    }
  end

  return nil
end

local function _parse_sse_events(buffer)
  local events = {}
  local remaining = buffer

  while true do
    local boundary = string_find(remaining, "\n\n", 1, true)
    if not boundary then
      break
    end

    local event_str = string_sub(remaining, 1, boundary - 1)
    remaining = string_sub(remaining, boundary + 2)

    local event = _parse_single_event(event_str)
    if event then
      events[#events + 1] = event
    end
  end

  return events, remaining
end

local function _extract_delta_tokens(event)
  if not event or event.data == "[DONE]" then
    return 0
  end

  local decoded
  if json_lib then
    decoded = json_lib.decode(event.data)
  end
  if decoded and type(decoded) == "table" then
    local choices = decoded.choices
    if type(choices) == "table" then
      local first_choice = choices[1]
      if type(first_choice) == "table" then
        local delta = first_choice.delta
        if type(delta) == "table" then
          local content = delta.content
          if type(content) == "string" and content ~= "" then
            return ceil(#content / 4)
          end
        end
      end
    end
  end

  local fallback_content = string_match(event.data, '"content"%s*:%s*"(.-)"')
  if type(fallback_content) ~= "string" or fallback_content == "" then
    return 0
  end

  return ceil(#fallback_content / 4)
end

local function _serialize_event(event)
  return event.raw .. "\n\n"
end

local function _actual_total_tokens(ctx)
  return (ctx.prompt_tokens or 0) + (ctx.tokens_used or 0)
end

local function _reconcile_once(ctx)
  if ctx.reconciled then
    return
  end

  ctx.reconciled = true

  if not llm_limiter or type(llm_limiter.reconcile) ~= "function" then
    return
  end

  local dict = ngx.shared and ngx.shared.fairvisor_counters
  if not dict then
    return
  end

  local reserved = ctx.reserved
  if type(reserved) ~= "number" or reserved <= 0 then
    return
  end

  local key = ctx.key
  if type(key) ~= "string" or key == "" then
    return
  end

  local now = utils.now()
  local ok, err = pcall(llm_limiter.reconcile, dict, key, ctx.config, reserved, _actual_total_tokens(ctx), now)
  if not ok then
    _log_err("_reconcile_once key=", key, " err=", tostring(err))
  end
end

local function _log_would_truncate(ctx)
  _log_info("body_filter reason=would_truncate key=", tostring(ctx.key),
    " tokens_used=", tostring(ctx.tokens_used),
    " max_completion_tokens=", tostring(ctx.max_completion_tokens))
end

function _M.is_streaming(request_context)
  if type(request_context) ~= "table" then
    return false
  end

  if request_context.stream == true then
    return true
  end

  if _detect_stream_flag_from_headers(request_context.headers) then
    return true
  end

  if _detect_stream_flag_from_body(request_context.body) then
    return true
  end

  return false
end

function _M.init_stream(config, request_context, reservation)
  local stream_settings = config and config.streaming or {}
  local enabled = stream_settings.enabled ~= false
  local enforce_mid_stream = stream_settings.enforce_mid_stream ~= false

  local ctx = {
    active = enabled and enforce_mid_stream and _M.is_streaming(request_context),
    config = config or {},
    key = reservation and reservation.key,
    reserved = reservation and reservation.estimated_total,
    prompt_tokens = reservation and reservation.prompt_tokens or 0,
    max_completion_tokens = (config and config.max_completion_tokens) or DEFAULT_MAX_COMPLETION_TOKENS,
    tokens_used = 0,
    chunk_count = 0,
    buffer = "",
    next_check = stream_settings.buffer_tokens or DEFAULT_BUFFER_TOKENS,
    on_limit_exceeded = stream_settings.on_limit_exceeded or DEFAULT_LIMIT_EXCEEDED_MODE,
    include_partial_usage = stream_settings.include_partial_usage ~= false,
    is_shadow = reservation and reservation.is_shadow or false,
    done = false,
    truncated = false,
    reconciled = false,
  }

  ngx.ctx = ngx.ctx or {}
  ngx.ctx.fairvisor_stream = ctx

  return ctx
end

function _M.body_filter(chunk, eof)
  local stream_ctx = ngx.ctx and ngx.ctx.fairvisor_stream
  if not stream_ctx or not stream_ctx.active then
    return chunk
  end

  if stream_ctx.truncated then
    if eof then
      _reconcile_once(stream_ctx)
    end
    return ""
  end

  local in_chunk = chunk or ""
  if in_chunk ~= "" then
    stream_ctx.buffer = stream_ctx.buffer .. in_chunk
  end

  local events, remaining = _parse_sse_events(stream_ctx.buffer)
  stream_ctx.buffer = remaining

  local out = {}

  for _, event in ipairs(events) do
    if event.data == "[DONE]" then
      stream_ctx.done = true
      _reconcile_once(stream_ctx)
      out[#out + 1] = _serialize_event(event)
      break
    end

    local delta_tokens = _extract_delta_tokens(event)
    stream_ctx.tokens_used = stream_ctx.tokens_used + delta_tokens
    stream_ctx.chunk_count = stream_ctx.chunk_count + 1

    if stream_ctx.tokens_used >= stream_ctx.next_check then
      local interval = stream_ctx.config.streaming and stream_ctx.config.streaming.buffer_tokens
      if type(interval) ~= "number" or interval <= 0 then
        interval = DEFAULT_BUFFER_TOKENS
      end

      while stream_ctx.tokens_used >= stream_ctx.next_check do
        stream_ctx.next_check = stream_ctx.next_check + interval
      end

      if stream_ctx.tokens_used > stream_ctx.max_completion_tokens then
        if stream_ctx.is_shadow then
          _log_would_truncate(stream_ctx)
        else
          stream_ctx.truncated = true
          _reconcile_once(stream_ctx)
          return _build_termination(stream_ctx)
        end
      end
    end

    out[#out + 1] = _serialize_event(event)
  end

  local processed = table_concat(out)

  if eof and stream_ctx.buffer ~= "" then
    processed = processed .. stream_ctx.buffer
    stream_ctx.buffer = ""
  end

  if eof then
    _reconcile_once(stream_ctx)
  end

  return processed
end

function _M.validate_config(config)
  if config == nil then
    return true
  end

  if type(config) ~= "table" then
    return nil, "config must be a table"
  end

  local stream_settings = config.streaming or config
  if type(stream_settings) ~= "table" then
    return nil, "streaming config must be a table"
  end

  if stream_settings.enabled == nil then
    stream_settings.enabled = true
  elseif type(stream_settings.enabled) ~= "boolean" then
    return nil, "streaming.enabled must be a boolean"
  end

  if stream_settings.enforce_mid_stream == nil then
    stream_settings.enforce_mid_stream = true
  elseif type(stream_settings.enforce_mid_stream) ~= "boolean" then
    return nil, "streaming.enforce_mid_stream must be a boolean"
  end

  if stream_settings.buffer_tokens == nil then
    stream_settings.buffer_tokens = DEFAULT_BUFFER_TOKENS
  elseif type(stream_settings.buffer_tokens) ~= "number" or stream_settings.buffer_tokens <= 0 then
    return nil, "streaming.buffer_tokens must be a positive number"
  end

  if stream_settings.on_limit_exceeded == nil then
    stream_settings.on_limit_exceeded = DEFAULT_LIMIT_EXCEEDED_MODE
  elseif stream_settings.on_limit_exceeded ~= "graceful_close" and stream_settings.on_limit_exceeded ~= "error_chunk" then
    return nil, "streaming.on_limit_exceeded must be graceful_close or error_chunk"
  end

  if stream_settings.include_partial_usage == nil then
    stream_settings.include_partial_usage = true
  elseif type(stream_settings.include_partial_usage) ~= "boolean" then
    return nil, "streaming.include_partial_usage must be a boolean"
  end

  return true
end

return _M
