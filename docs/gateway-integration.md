# Gateway Integration

This guide provides reference snippets for integrating Fairvisor Edge as an inline decision service. Replace `fairvisor-edge.default.svc.cluster.local:8080` with your Edge deployment URL.

## Contents

- [Policy field reference](#policy-field-reference)
- [Decision API contract](#decision-api-contract)
- [nginx `auth_request`](#nginx-auth_request)
- [Envoy `ext_authz`](#envoy-ext_authz)
- [Kong (pre-function)](#kong-pre-function)
- [Traefik `forwardAuth`](#traefik-forwardauth)
- [Emergency rollback](#emergency-rollback-standalone)

## Policy field reference

For detailed bundle/policy/rule field descriptions (types, required fields, validation, defaults, and examples), see `docs/policy-reference.md`.

## Decision API contract

| Item | Value |
|------|--------|
| Endpoint | `POST /v1/decision` |
| Request headers | `Authorization` (optional), `X-Original-Method`, `X-Original-URI` (required in decision_service mode so Edge sees the original request) |
| Success | `200` — request allowed |
| Reject | `429` — too many requests / rate limit; response headers: `X-Fairvisor-Reason`, `Retry-After`, `RateLimit`, `RateLimit-Reset` |
| Error | `503` — no bundle loaded / service unavailable |

When the gateway cannot reach Edge (timeout, connection refused), configure fail-open vs fail-closed per your policy (e.g. nginx `auth_request` fails closed by default).
Response body is not part of the contract; integrations must rely on HTTP status + headers.

**Health:** Edge exposes:
- `GET /livez` -> `200` when process is alive.
- `GET /readyz` -> `200` only after a bundle is loaded, otherwise `503`.
- `GET /metrics` -> Prometheus metrics endpoint.

**Timeouts:** Keep the gateway→Edge timeout low (e.g. 200–500 ms) so the decision path does not add significant p99 latency.

## nginx `auth_request`

```nginx
upstream fairvisor_edge {
  server fairvisor-edge.default.svc.cluster.local:8080;
}

server {
  listen 80;

  location = /_fairvisor_decision {
    internal;
    proxy_method POST;
    proxy_pass http://fairvisor_edge/v1/decision;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URI $request_uri;
    proxy_set_header X-Original-Method $request_method;
    proxy_set_header Authorization $http_authorization;
  }

  location / {
    auth_request /_fairvisor_decision;
    auth_request_set $fairvisor_reason $upstream_http_x_fairvisor_reason;
    auth_request_set $fairvisor_retry $upstream_http_retry_after;
    proxy_pass http://your_backend;
  }
}
```

Optional: use `auth_request_set` to pass `X-Fairvisor-*` and `Retry-After` to the backend or to custom error pages. For fail-open when Edge is down, use `proxy_intercept_errors` and `error_page` on the internal location.

## Envoy `ext_authz`

```yaml
static_resources:
  clusters:
    - name: fairvisor_edge
      connect_timeout: 0.25s
      type: STRICT_DNS
      load_assignment:
        cluster_name: fairvisor_edge
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: fairvisor-edge.default.svc.cluster.local
                      port_value: 8080
  listeners:
    - name: listener_0
      address:
        socket_address:
          address: 0.0.0.0
          port_value: 10000
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: ingress_http
                http_filters:
                  - name: envoy.filters.http.ext_authz
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz
                      http_service:
                        server_uri:
                          uri: http://fairvisor_edge
                          cluster: fairvisor_edge
                          timeout: 0.25s
                        authorization_request:
                          allowed_headers:
                            patterns:
                              - exact: authorization
                              - exact: x-forwarded-for
                              - exact: x-original-method
                              - exact: x-original-uri
                        path_prefix: /v1/decision
                  - name: envoy.filters.http.router
                route_config:
                  name: local_route
                  virtual_hosts:
                    - name: backend
                      domains: ["*"]
                      routes:
                        - match: { prefix: "/" }
                          route: { cluster: your_backend }
```

## Kong (pre-function)

Uses Kong's pre-function plugin to call the decision endpoint. Prefer passing the full original URI (path + query) so route matching works correctly.

```yaml
plugins:
  - name: pre-function
    config:
      access:
        - |
          local http = require("resty.http")
          local client = http.new()
          local path = kong.request.get_path()
          local query = kong.request.get_raw_query()
          local uri = query and (path .. "?" .. query) or path
          local res, err = client:request_uri("http://fairvisor-edge.default.svc.cluster.local:8080/v1/decision", {
            method = "POST",
            headers = {
              ["Authorization"] = kong.request.get_header("authorization"),
              ["X-Original-URI"] = uri,
              ["X-Original-Method"] = kong.request.get_method(),
            }
          })
          if not res or res.status >= 400 then
            local status = (res and res.status) or 503
            local body = (res and res.body) or "fairvisor unreachable"
            return kong.response.exit(status == 429 and 429 or 403, { message = body })
          end
```

## Traefik `forwardAuth`

Forward auth middleware. List the response headers that Traefik should copy from the auth service into the request to your backend (so apps can read reason, policy, retry-after).

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: fairvisor-forward-auth
spec:
  forwardAuth:
    address: http://fairvisor-edge.default.svc.cluster.local:8080/v1/decision
    trustForwardHeader: true
    authResponseHeaders:
      - X-Fairvisor-Reason
      # Policy/rule attribution is debug-session only (X-Fairvisor-Debug-*).
      - Retry-After
```

## Emergency rollback (standalone)

Use when Edge is deployed in standalone mode (local policy file) and you need to revert to a known-good policy (e.g. after a bad push or SaaS outage).

```bash
cp /etc/fairvisor/policy.backup.json /etc/fairvisor/policy.json
kill -HUP $(pidof nginx)
```

On `SIGHUP`, nginx reloads workers and Fairvisor re-reads `FAIRVISOR_CONFIG_FILE` during `init_worker`. Ensure `policy.backup.json` is updated by your deployment or backup job.
