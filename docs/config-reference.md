# Configuration Reference

Runtime configuration is controlled by environment variables.

## Core Runtime Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `FAIRVISOR_MODE` | no | `decision_service` | Runtime mode. Allowed: `decision_service`, `reverse_proxy`. |
| `FAIRVISOR_CONFIG_FILE` | conditional | none | Path to local bundle file in standalone mode. Required when `FAIRVISOR_SAAS_URL` is not set. |
| `FAIRVISOR_SAAS_URL` | conditional | none | Base URL for SaaS mode. When set, `FAIRVISOR_EDGE_ID` and `FAIRVISOR_EDGE_TOKEN` are required. |
| `FAIRVISOR_EDGE_ID` | conditional | none | Edge identity for SaaS mode. |
| `FAIRVISOR_EDGE_TOKEN` | conditional | none | Bearer token for SaaS mode API calls. |
| `FAIRVISOR_BACKEND_URL` | conditional | none in module, `http://127.0.0.1:8081` in Docker entrypoint | Required when `FAIRVISOR_MODE=reverse_proxy`. |

## Polling / Sync Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `FAIRVISOR_CONFIG_POLL_INTERVAL` | no | `30` | Config pull interval (seconds). Must be positive. |
| `FAIRVISOR_HEARTBEAT_INTERVAL` | no | `5` | Heartbeat interval (seconds). Must be positive. |
| `FAIRVISOR_EVENT_FLUSH_INTERVAL` | no | `60` | Event flush interval (seconds). Must be positive. |

## Nginx / Container Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `FAIRVISOR_SHARED_DICT_SIZE` | no | `128m` | Shared dict size for counters/state. |
| `FAIRVISOR_LOG_LEVEL` | no | `info` | Nginx error log level. |
| `FAIRVISOR_WORKER_PROCESSES` | no | `auto` | Nginx worker processes (template variable). |
| `FAIRVISOR_DEBUG_SESSION_SECRET` | no | unset | Enables per-user debug session endpoints (`POST /v1/debug/session`, `POST /v1/debug/logout`) that emit `X-Fairvisor-Debug-*` headers for requests with valid debug cookie. |

## CLI-Specific Variables

| Variable | Used by | Description |
|---|---|---|
| `FAIRVISOR_EDGE_URL` | `fairvisor status` | Edge base URL fallback (default `http://localhost:8080`). |
| `FAIRVISOR_NON_INTERACTIVE` | `fairvisor connect` | Set to `1` to disable prompts. |
| `CI` | `fairvisor connect` | `CI=true` also enables non-interactive behavior. |

## E2E Test Variables

| Variable | Default | Description |
|---|---|---|
| `FAIRVISOR_E2E_URL` | `http://localhost:18080` | Base URL for E2E suite. |
| `FAIRVISOR_E2E_DEBUG_URL` | `http://localhost:18081` | Debug container URL for E2E suite. |
| `FAIRVISOR_E2E_HEALTH_TIMEOUT` | `15` | Health wait timeout in seconds for E2E. |

## Mode Rules Summary

- Standalone mode: set `FAIRVISOR_CONFIG_FILE`.
- SaaS mode: set `FAIRVISOR_SAAS_URL`, `FAIRVISOR_EDGE_ID`, and `FAIRVISOR_EDGE_TOKEN`.
- Reverse proxy mode: set `FAIRVISOR_MODE=reverse_proxy` and `FAIRVISOR_BACKEND_URL`.
