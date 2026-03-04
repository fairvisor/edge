-- luacheck configuration for OpenResty/LuaJIT project

-- OpenResty globals available at runtime via nginx/LuaJIT.
-- Listed as globals (not read_globals) because production code and tests
-- write to fields like ngx.status, ngx.header, ngx.ctx, etc.
globals = {
  "ngx",
  "ndk",
  "jit",
}

max_line_length = 140

-- Exclude generated or vendored paths
exclude_files = { "spec/helpers/mock_ngx.lua" }

-- Test files monkey-patch standard globals (math.random, os.getenv)
-- and use intentionally-unused callback arguments (self, ctx).
files["spec/**"] = {
  globals = { "math", "os" },
  ignore = { "212" },  -- unused arguments in mock/callback functions
}
