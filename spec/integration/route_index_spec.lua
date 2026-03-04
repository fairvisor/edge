package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local route_index = require("fairvisor.route_index")
local gherkin = require("helpers.gherkin")

local runner = gherkin.new({ describe = describe, context = context, it = it })

runner:given("^a mixed policy bundle with exact and prefix selectors$", function(ctx)
  ctx.policies = {
    {
      id = "policy-global",
      spec = {
        selector = {
          pathPrefix = "/",
        },
      },
    },
    {
      id = "policy-v1",
      selector = {
        pathPrefix = "/v1",
      },
    },
    {
      id = "policy-chat",
      spec = {
        selector = {
          pathPrefix = "/v1/chat/",
        },
      },
    },
    {
      id = "policy-chat-post",
      selector = {
        pathExact = "/v1/chat/completions",
        methods = { "POST" },
      },
    },
    {
      id = "policy-data-get",
      spec = {
        selector = {
          pathExact = "/v1/data",
          methods = { "GET" },
        },
      },
    },
  }
end)

runner:given("^a mixed policy bundle with host%-specific and global selectors$", function(ctx)
  ctx.policies = {
    {
      id = "policy-global",
      spec = {
        selector = {
          pathPrefix = "/v1/",
        },
      },
    },
    {
      id = "policy-api-host",
      spec = {
        selector = {
          hosts = { "api.example.com" },
          pathPrefix = "/v1/",
        },
      },
    },
    {
      id = "policy-admin-host",
      spec = {
        selector = {
          hosts = { "admin.example.com" },
          pathPrefix = "/v1/",
        },
      },
    },
  }
end)

runner:when("^I build a route index from the bundle$", function(ctx)
  ctx.index, ctx.err = route_index.build(ctx.policies)
end)

runner:when('^I evaluate method "([^"]+)" and path "([^"]+)"$', function(ctx, method, path)
  ctx.matches = ctx.index:match(method, path)
  ctx.match_set = {}
  for i = 1, #ctx.matches do
    ctx.match_set[ctx.matches[i]] = true
  end
end)

runner:when('^I evaluate host "([^"]+)" method "([^"]+)" and path "([^"]+)"$', function(ctx, host, method, path)
  ctx.matches = ctx.index:match(host, method, path)
  ctx.match_set = {}
  for i = 1, #ctx.matches do
    ctx.match_set[ctx.matches[i]] = true
  end
end)

runner:then_("^the index build succeeds$", function(ctx)
  assert.is_table(ctx.index)
  assert.is_nil(ctx.err)
end)

runner:then_('^the matches include "([^"]+)"$', function(ctx, id)
  assert.is_true(ctx.match_set[id] == true)
end)

runner:then_('^the matches do not include "([^"]+)"$', function(ctx, id)
  assert.is_nil(ctx.match_set[id])
end)

runner:feature_file_relative("features/route_index.feature")
