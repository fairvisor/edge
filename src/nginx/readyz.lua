local health = require("fairvisor.health")
local ready, not_ready = health.readyz()
if ready ~= nil then
  local cjson = require("cjson.safe")
  ngx.status = 200
  ngx.say(cjson.encode(ready))
  return
end
local cjson = require("cjson.safe")
ngx.status = 503
ngx.say(cjson.encode(not_ready or { status = "not_ready", reason = "unknown" }))
