if ngx.var.fairvisor_mode ~= "reverse_proxy" then
  return
end

local decision_api = require("fairvisor.decision_api")
decision_api.header_filter_handler()
