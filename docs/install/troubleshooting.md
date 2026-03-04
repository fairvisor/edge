# Installation Troubleshooting

## Edge does not start

Check container logs first:

```bash
docker logs fairvisor-edge
```

Common causes:

- neither `FAIRVISOR_SAAS_URL` nor `FAIRVISOR_CONFIG_FILE` is set
- `FAIRVISOR_MODE=reverse_proxy` but `FAIRVISOR_BACKEND_URL` is missing
- `FAIRVISOR_SAAS_URL` is set but edge credentials are missing

## Readiness stays failing

Verify policy source:

- Standalone mode: mounted file exists at `FAIRVISOR_CONFIG_FILE`
- SaaS mode: edge can reach `FAIRVISOR_SAAS_URL`

Probe endpoints:

```bash
curl -i http://127.0.0.1:8080/livez
curl -i http://127.0.0.1:8080/readyz
```

## Helm install fails validation

The chart enforces value rules. Check:

- `mode` is valid (`decision_service` or `reverse_proxy`)
- `backendUrl` is set when `mode=reverse_proxy`
- exactly one policy source is set (SaaS or standalone)
- SaaS token source is exactly one of inline token or Secret ref

## Debug decision path

Use a per-session debug cookie. Set `FAIRVISOR_DEBUG_SESSION_SECRET` and call `POST /v1/debug/session` to obtain a signed cookie. Requests with that cookie emit `X-Fairvisor-Debug-*` headers.
