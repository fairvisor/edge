if ngx.req.get_method() ~= "POST" then
  ngx.status = 405
  ngx.exit(405)
  return
end
local decision_api = require("fairvisor.decision_api")
decision_api.access_handler()
ngx.status = 200
ngx.exit(200)
