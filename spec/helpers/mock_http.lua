local _M = {}

function _M.new()
  local state = {
    queues = {},
    requests = {},
  }

  local function make_key(method, url)
    return method .. " " .. url
  end

  local function push_response(method, url, response, err)
    local key = make_key(method, url)
    local queue = state.queues[key]
    if not queue then
      queue = {}
      state.queues[key] = queue
    end

    queue[#queue + 1] = {
      response = response,
      err = err,
    }
  end

  local function pop_response(method, url)
    local key = make_key(method, url)
    local queue = state.queues[key]
    if not queue or #queue == 0 then
      return nil, "no mock response for " .. key
    end

    local entry = queue[1]
    for i = 2, #queue do
      queue[i - 1] = queue[i]
    end
    queue[#queue] = nil
    return entry.response, entry.err
  end

  local client = {}

  function client:post(url, body, headers)
    state.requests[#state.requests + 1] = {
      method = "POST",
      url = url,
      body = body,
      headers = headers,
    }
    return pop_response("POST", url)
  end

  function client:get(url, headers)
    state.requests[#state.requests + 1] = {
      method = "GET",
      url = url,
      headers = headers,
    }
    return pop_response("GET", url)
  end

  return {
    client = client,
    queue_response = push_response,
    requests = state.requests,
  }
end

return _M
