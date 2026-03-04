local health = require("fairvisor.health")
ngx.status = 200
ngx.say(health.render() or "")
