local match = string.match
local gmatch = string.gmatch
local sub = string.sub
local type = type
local unpack = table.unpack or unpack

local _M = {}

local function _trim(text)
  return match(text, "^%s*(.-)%s*$")
end

local function _starts_with(text, prefix)
  return sub(text, 1, #prefix) == prefix
end

local function _normalize_step_text(step)
  local parsed = step
  if _starts_with(parsed, "Given ") then
    parsed = sub(parsed, 7)
  elseif _starts_with(parsed, "When ") then
    parsed = sub(parsed, 6)
  elseif _starts_with(parsed, "Then ") then
    parsed = sub(parsed, 6)
  elseif _starts_with(parsed, "And ") then
    parsed = sub(parsed, 5)
  end
  return _trim(parsed)
end

local function _new_scenario(title)
  return {
    title = title,
    steps = {},
  }
end

local function _new_rule(title)
  return {
    title = title,
    scenarios = {},
  }
end

local function _new_feature(title)
  return {
    title = title,
    rules = {},
  }
end

local function _parse(feature_text)
  local feature
  local current_rule
  local current_scenario

  for raw_line in gmatch(feature_text, "[^\r\n]+") do
    local line = _trim(raw_line)
    if line ~= "" then
      if _starts_with(line, "Feature:") then
        local title = _trim(sub(line, 9))
        feature = _new_feature(title)
        current_rule = nil
        current_scenario = nil
      elseif _starts_with(line, "Rule:") then
        if not feature then
          return nil, "Rule declared before Feature"
        end
        local title = _trim(sub(line, 6))
        current_rule = _new_rule(title)
        current_scenario = nil
        feature.rules[#feature.rules + 1] = current_rule
      elseif _starts_with(line, "Scenario:") then
        if not feature then
          return nil, "Scenario declared before Feature"
        end
        if not current_rule then
          current_rule = _new_rule("Default rule")
          feature.rules[#feature.rules + 1] = current_rule
        end
        local title = _trim(sub(line, 10))
        current_scenario = _new_scenario(title)
        current_rule.scenarios[#current_rule.scenarios + 1] = current_scenario
      elseif _starts_with(line, "Given ") or _starts_with(line, "When ")
          or _starts_with(line, "Then ") or _starts_with(line, "And ") then
        if not current_scenario then
          return nil, "Step declared before Scenario"
        end
        local step_text = _normalize_step_text(line)
        current_scenario.steps[#current_scenario.steps + 1] = step_text
      end
    end
  end

  if not feature then
    return nil, "Feature block was not found"
  end

  return feature
end

local function _find_step_definition(step_definitions, step_text)
  for _, definition in ipairs(step_definitions) do
    local captures = { match(step_text, definition.pattern) }
    if #captures > 0 then
      return definition.handler, captures
    end
  end

  return nil, nil
end

function _M.new(framework)
  local test_framework = framework or {}
  local runner = {
    step_definitions = {},
    describe = test_framework.describe,
    context = test_framework.context,
    it = test_framework.it,
  }

  function runner:step(pattern, handler)
    if type(pattern) ~= "string" or pattern == "" then
      return nil, "step pattern must be a non-empty string"
    end
    if type(handler) ~= "function" then
      return nil, "step handler must be a function"
    end

    self.step_definitions[#self.step_definitions + 1] = {
      pattern = pattern,
      handler = handler,
    }
    return true
  end

  function runner:given(pattern, handler)
    return self:step(pattern, handler)
  end

  function runner:when(pattern, handler)
    return self:step(pattern, handler)
  end

  function runner:then_(pattern, handler)
    return self:step(pattern, handler)
  end

  function runner:feature(feature_text)
    local parsed, parse_err = _parse(feature_text)
    if not parsed then
      return nil, parse_err
    end

    local describe_fn = self.describe
    local context_fn = self.context or self.describe
    local it_fn = self.it
    if type(describe_fn) ~= "function" or type(context_fn) ~= "function" or type(it_fn) ~= "function" then
      return nil, "busted describe/context/it functions are not available"
    end

    describe_fn(parsed.title, function()
      for _, rule in ipairs(parsed.rules) do
        context_fn(rule.title, function()
          for _, scenario in ipairs(rule.scenarios) do
            it_fn(scenario.title, function()
              local scenario_context = {}
              for _, step_text in ipairs(scenario.steps) do
                local handler, captures = _find_step_definition(self.step_definitions, step_text)
                assert(handler ~= nil, "missing step definition for: " .. step_text)
                handler(scenario_context, unpack(captures))
              end
            end)
          end
        end)
      end
    end)

    return true
  end

  --- Load and run a feature from a file path relative to the calling spec file.
  -- Use so that Feature/Rule/Scenario live in .feature files and step defs stay in _spec.lua.
  -- @param rel_path (string) path relative to the spec file directory, e.g. "features/shadow_mode.feature"
  -- @return true on success, nil, error_message on failure
  function runner:feature_file_relative(rel_path)
    local info = debug.getinfo(2, "S")
    local source = info and info.source
    if type(source) ~= "string" or sub(source, 1, 1) ~= "@" then
      return nil, "could not resolve spec file path for feature_file_relative"
    end
    local spec_path = sub(source, 2)
    local dir = match(spec_path, "^(.*)[/\\]")
    if not dir then
      dir = "."
    end
    local full_path = dir .. "/" .. rel_path
    local f = io.open(full_path, "r")
    if not f then
      return nil, "could not open feature file: " .. full_path
    end
    local content = f:read("*a")
    f:close()
    return self:feature(content)
  end

  return runner
end

return _M
