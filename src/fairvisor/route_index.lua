local gmatch = string.gmatch
local gsub = string.gsub
local lower = string.lower
local match = string.match
local sub = string.sub
local type = type

local _M = {}

local function _log_warn(...)
  if ngx and ngx.log then ngx.log(ngx.WARN, ...) end
end

local function _new_node()
  return {
    children = {},
    policies_exact = {},
    policies_prefix = {},
  }
end

local function _clear_segments(segments)
  for i = #segments, 1, -1 do
    segments[i] = nil
  end
end

local function _split_path(path, out_segments)
  local segments = out_segments or {}
  if out_segments then
    _clear_segments(out_segments)
  end

  local count = 0
  for segment in gmatch(path, "[^/]+") do
    count = count + 1
    segments[count] = segment
  end

  return segments, count
end

local function _build_methods_set(methods)
  if methods == nil then
    return nil
  end

  if type(methods) ~= "table" then
    return {}
  end

  local method_set = {}
  for _, method in ipairs(methods) do
    if type(method) == "string" and method ~= "" then
      method_set[method] = true
    end
  end

  return method_set
end

local function _normalize_prefix(path_prefix)
  if type(path_prefix) ~= "string" or path_prefix == "" then
    return nil
  end

  if sub(path_prefix, 1, 1) ~= "/" then
    return nil
  end

  if path_prefix == "/" then
    return path_prefix
  end

  if sub(path_prefix, -1) ~= "/" then
    return path_prefix .. "/"
  end

  return path_prefix
end

local function _is_valid_exact_path(path_exact)
  return type(path_exact) == "string" and path_exact ~= "" and sub(path_exact, 1, 1) == "/"
end

local function _normalize_host(host)
  if type(host) ~= "string" then
    return nil
  end

  local trimmed = match(host, "^%s*(.-)%s*$")
  if trimmed == nil or trimmed == "" then
    return nil
  end

  local normalized = lower(trimmed)
  local without_port = match(normalized, "^([^:]+):%d+$")
  if without_port and without_port ~= "" then
    normalized = without_port
  end

  normalized = gsub(normalized, "%.$", "")
  if normalized == "" then
    return nil
  end

  return normalized
end

local function _traverse_or_create(root, segments, segment_count)
  local node = root
  for i = 1, segment_count do
    local segment = segments[i]
    local child = node.children[segment]
    if not child then
      child = _new_node()
      node.children[segment] = child
    end
    node = child
  end
  return node
end

local function _method_matches(methods, method)
  if methods == nil then
    return true
  end

  return methods[method] == true
end

-- pathPrefix at a node applies only when request has at least min_depth segments.
-- e.g. prefix "/v1/" has min_depth 2 so "/v1" (depth 1) does not match; "/v1/x" (depth 2) does.
local function _collect_prefix_matches(node, method, request_depth, out)
  local policies = node.policies_prefix
  for i = 1, #policies do
    local entry = policies[i]
    if request_depth >= entry.min_depth and _method_matches(entry.methods, method) then
      out[#out + 1] = entry.id
    end
  end
end

local function _collect_exact_matches(node, method, path, out)
  local policies = node.policies_exact
  for i = 1, #policies do
    local entry = policies[i]
    if entry.path == path and _method_matches(entry.methods, method) then
      out[#out + 1] = entry.id
    end
  end
end

local function _dedupe_sorted_ids(matches)
  if #matches < 2 then
    return matches
  end

  local deduped = {}
  local last_id = nil

  for i = 1, #matches do
    local current_id = matches[i]
    if current_id ~= last_id then
      deduped[#deduped + 1] = current_id
      last_id = current_id
    end
  end

  return deduped
end

local function _index_match_in_root(root, scratch_segments, method, path, out)
  if path == nil or type(path) ~= "string" or path == "" then
    return out
  end

  local matches = out or {}
  local segments, depth = _split_path(path, scratch_segments)
  local node = root

  _collect_prefix_matches(root, method, depth, matches)

  for i = 1, depth do
    node = node.children[segments[i]]
    if node == nil then
      break
    end
    _collect_prefix_matches(node, method, depth, matches)
  end

  if node ~= nil then
    _collect_exact_matches(node, method, path, matches)
  end

  return matches
end

-- Returns matching policy IDs. Supports both signatures:
-- match(method, path) and match(host, method, path).
-- Order: prefix matches by traversal depth (root → leaf), then exact at leaf; IDs sorted for deterministic output.
-- Contract: path must be a non-empty string; nil or invalid path returns {}.
local function _index_match(self, host_or_method, method_or_path, maybe_path)
  local host = nil
  local method = host_or_method
  local path = method_or_path

  if maybe_path ~= nil then
    host = host_or_method
    method = method_or_path
    path = maybe_path
  end

  if path == nil or type(path) ~= "string" or path == "" then
    return {}
  end

  local matches = {}
  local normalized_host = _normalize_host(host)
  local host_root = normalized_host and self.roots_by_host[normalized_host] or nil
  local wildcard_root = self.roots_by_host["*"]

  if host_root then
    _index_match_in_root(host_root, self._scratch_segments_host, method, path, matches)
  end

  if wildcard_root then
    _index_match_in_root(wildcard_root, self._scratch_segments_wildcard, method, path, matches)
  end

  table.sort(matches)
  return _dedupe_sorted_ids(matches)
end

local function _insert_selector(root, policy_id, selector, methods)
  local added = false

  local path_exact = selector.pathExact
  if path_exact ~= nil then
    if _is_valid_exact_path(path_exact) then
      local exact_segments, exact_depth = _split_path(path_exact)
      local exact_node = _traverse_or_create(root, exact_segments, exact_depth)
      exact_node.policies_exact[#exact_node.policies_exact + 1] = {
        id = policy_id,
        methods = methods,
        path = path_exact,
      }
      added = true
    else
      _log_warn("build policy_id=", policy_id or "unknown", " invalid pathExact, skipping exact selector")
    end
  end

  local normalized_prefix = _normalize_prefix(selector.pathPrefix)
  if selector.pathPrefix ~= nil and not normalized_prefix then
    _log_warn("build policy_id=", policy_id or "unknown", " invalid pathPrefix, skipping prefix selector")
  elseif normalized_prefix then
    local prefix_segments, prefix_depth = _split_path(normalized_prefix)
    local prefix_node = _traverse_or_create(root, prefix_segments, prefix_depth)
    -- Root prefix "/" matches any path (depth >= 0). Other prefixes require at least one segment after the prefix.
    local min_depth = (normalized_prefix == "/") and 0 or (prefix_depth + 1)
    prefix_node.policies_prefix[#prefix_node.policies_prefix + 1] = {
      id = policy_id,
      methods = methods,
      min_depth = min_depth,
    }
    added = true
  end

  return added
end

function _M.build(policies)
  if type(policies) ~= "table" then
    return nil, "policies must be a table"
  end

  local roots_by_host = {
    ["*"] = _new_node(),
  }

  for i = 1, #policies do
    local policy = policies[i]
    if type(policy) ~= "table" then
      _log_warn("build policy_id=unknown invalid policy entry (not a table), skipping")
    else
      local policy_id = policy.id
      if type(policy_id) ~= "string" or policy_id == "" then
        _log_warn("build policy_id=unknown missing or invalid policy id, skipping")
      else
        local selector = policy.spec and policy.spec.selector or policy.selector
        if type(selector) ~= "table" then
          _log_warn("build policy_id=", policy_id or "unknown", " missing selector, skipping")
        else
          local methods = _build_methods_set(selector.methods)
          local hosts = selector.hosts
          local has_hosts = type(hosts) == "table" and #hosts > 0
          local added_any = false

          if has_hosts then
            for host_index = 1, #hosts do
              local normalized_host = _normalize_host(hosts[host_index])
              if normalized_host then
                local host_root = roots_by_host[normalized_host]
                if not host_root then
                  host_root = _new_node()
                  roots_by_host[normalized_host] = host_root
                end
                if _insert_selector(host_root, policy_id, selector, methods) then
                  added_any = true
                end
              else
                _log_warn("build policy_id=", policy_id or "unknown", " invalid host at index ", host_index, ", skipping host selector")
              end
            end
          else
            if _insert_selector(roots_by_host["*"], policy_id, selector, methods) then
              added_any = true
            end
          end

          if not added_any then
            _log_warn("build policy_id=", policy_id or "unknown", " selector has neither valid pathExact nor pathPrefix, skipping policy")
          end
        end
      end
    end
  end

  return {
    roots_by_host = roots_by_host,
    _scratch_segments_host = {},
    _scratch_segments_wildcard = {},
    match = _index_match,
  }
end

return _M
