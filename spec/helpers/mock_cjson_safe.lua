local tonumber = tonumber
local type = type

local _M = {}

local function _decode(body)
  if type(body) ~= "string" then
    return nil, "invalid"
  end

  local p, c, t = body:match('^{"usage":{"prompt_tokens":(-?%d+),"completion_tokens":(-?%d+),"total_tokens":(-?%d+)}}$')
  if p and c and t then
    return { usage = { prompt_tokens = tonumber(p), completion_tokens = tonumber(c), total_tokens = tonumber(t) } }
  end

  local t2, p2, c2 = body:match('^{"usage":{"total_tokens":(-?%d+),"prompt_tokens":(-?%d+),"completion_tokens":(-?%d+)}}$')
  if t2 and p2 and c2 then
    return { usage = { total_tokens = tonumber(t2), prompt_tokens = tonumber(p2), completion_tokens = tonumber(c2) } }
  end

  local p3, c3 = body:match('^{"usage":{"prompt_tokens":(-?%d+),"completion_tokens":(-?%d+)}}$')
  if p3 and c3 then
    return { usage = { prompt_tokens = tonumber(p3), completion_tokens = tonumber(c3) } }
  end

  local t4 = body:match('^{"usage":{"total_tokens":(-?%d+)}}$')
  if t4 then
    return { usage = { total_tokens = tonumber(t4) } }
  end

  local t5 = body:match('^{"data":{"usage":{"total_tokens":(-?%d+)}}}$')
  if t5 then
    return { data = { usage = { total_tokens = tonumber(t5) } } }
  end

  if body == '{"result":"ok"}' then
    return { result = "ok" }
  end

  if body == '{"done":true}' then
    return { done = true }
  end

  return nil, "decode error"
end

function _M.install()
  package.loaded["cjson.safe"] = { decode = _decode }
end

return _M
