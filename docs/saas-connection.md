# SaaS Connection Guide

## 1. Register an edge

Use CLI connect:

```bash
./bin/fairvisor connect --token=<EDGE_TOKEN> --url=https://api.fairvisor.com
```

Behavior:

- Calls `POST /api/v1/edge/register` with edge version.
- On success, expects `edge_id` in response.
- Writes env file (default `/etc/fairvisor/edge.env`; fallback `./edge.env` if not writable).
- Attempts initial policy download from `GET /api/v1/edge/config` into `/etc/fairvisor/policy.json`.

## 2. Required SaaS runtime env

For SaaS mode, these must be set:

- `FAIRVISOR_SAAS_URL`
- `FAIRVISOR_EDGE_ID`
- `FAIRVISOR_EDGE_TOKEN`

If SaaS URL is set without edge ID/token, container startup fails.

## 3. Run edge in SaaS mode

Example:

```bash
docker run --rm -p 8080:8080 \
  -e FAIRVISOR_SAAS_URL=https://api.fairvisor.com \
  -e FAIRVISOR_EDGE_ID=<EDGE_ID> \
  -e FAIRVISOR_EDGE_TOKEN=<EDGE_TOKEN> \
  fairvisor-edge:local
```

## 4. Verify connectivity

Local checks:

```bash
./bin/fairvisor status --edge-url=http://localhost:8080
curl -sS http://localhost:8080/readyz
```

`fairvisor status` reads:

- `/readyz` for readiness
- `/metrics` for policy version / SaaS reachability / decision counters

## 5. Runtime SaaS sync behavior

The SaaS client performs:

- edge registration
- periodic heartbeat
- config pull (`/api/v1/edge/config`)
- config ack (`/api/v1/edge/config/ack`)
- event batching and flush

It uses retries with backoff and jitter, and a simple circuit-breaker state machine for repeated failures.

## 6. Graceful shutdown and event flush

During worker shutdown, Edge attempts to flush buffered SaaS events before exit.

- Nginx uses `worker_shutdown_timeout 35s`.
- Shutdown handler calls SaaS event flush (`flush_events()`).
- If process is force-killed before the timeout window, buffered events can be lost.

Operational recommendation: configure orchestrator termination grace period >= 35 seconds for SaaS-connected deployments.

## 7. Common connection failures

| Symptom | Likely cause | Fix |
|---|---|---|
| `FAIRVISOR_EDGE_ID is required when FAIRVISOR_SAAS_URL is set` | Missing edge ID env | Set `FAIRVISOR_EDGE_ID`. |
| `FAIRVISOR_EDGE_TOKEN is required when FAIRVISOR_SAAS_URL is set` | Missing token env | Set `FAIRVISOR_EDGE_TOKEN`. |
| `Connection failed: unauthorized` from CLI connect | Invalid/expired token | Rotate token and retry. |
| `Edge not reachable` in `fairvisor status` | Wrong edge URL or edge down | Verify URL, container, network, and port mapping. |
| SaaS shown as disconnected | Upstream unreachable or auth errors | Check SaaS URL, token, and outbound network. |

## 8. Non-interactive connect

For automation:

- provide `--token` and `--url`
- or set env vars
- set `FAIRVISOR_NON_INTERACTIVE=1` (or `CI=true`) to disable prompts
