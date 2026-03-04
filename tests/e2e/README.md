# E2E tests (Fairvisor Edge)

End-to-end tests run against a real Edge container (Docker). They validate the **gateway integration contract** (health probes, Decision API) from [docs/gateway-integration.md](../../docs/gateway-integration.md).

## Prerequisites

- Docker and Docker Compose
- Python 3.9+ with `tests/e2e/requirements.txt` installed
## Run

1. From the **repo root**:

   ```bash
   docker compose -f tests/e2e/docker-compose.test.yml up -d --build
   ```

2. Wait for the container to be healthy (or up to ~15 s). Then:

   ```bash
   pip install -r tests/e2e/requirements.txt
   pytest tests/e2e -v
   ```

3. Optional: override Edge URL and health timeout:

   ```bash
   FAIRVISOR_E2E_URL=http://localhost:18080 FAIRVISOR_E2E_HEALTH_TIMEOUT=20 pytest tests/e2e -v
   ```

   Additional optional URLs:

   ```bash
   FAIRVISOR_E2E_HOSTS_URL=http://localhost:18082 FAIRVISOR_E2E_5M_URL=http://localhost:18083 FAIRVISOR_E2E_NOBUNDLE_URL=http://localhost:18084 FAIRVISOR_E2E_REVERSE_URL=http://localhost:18085 FAIRVISOR_E2E_ASN_URL=http://localhost:18087 pytest tests/e2e -v
   ```

## Scenarios

- **Health:** `GET /livez` returns 200; `GET /readyz` returns 200 only when a bundle is loaded, 503 otherwise.
- **Decision API:** `POST /v1/decision` with `X-Original-Method` and `X-Original-URI` returns 200 (gateway snippet contract). Optional `Authorization` and query string in URI.
- **Metrics:** `GET /metrics` returns Prometheus text and includes decision counters.
- **Debug headers:** when a valid debug cookie is present (see `FAIRVISOR_DEBUG_SESSION_SECRET`), responses include `X-Fairvisor-Debug-Decision`, `X-Fairvisor-Debug-Mode`, `X-Fairvisor-Debug-Latency-Us`.
- **No bundle path:** `POST /v1/decision` returns `503`.
- **Reverse proxy enforcement:** in `FAIRVISOR_MODE=reverse_proxy`, allowed traffic is proxied to backend and repeated requests with same key are rejected by limiter.
- **Hosts selector:** host-scoped policy applies only when `X-Original-Host` matches `selector.hosts`.
- **5m budget window:** `cost_based` policy with `period=5m` rejects after budget exhaustion and returns `Retry-After` in-window.
- **ASN type mapping:** `X-ASN` is mapped through `asn_type.map` and used as `ip:type` descriptor for enforcement.
- **Tor selector:** nginx `geo` classification sets `ip:tor`; tor/non-tor traffic can be partitioned and enforced independently (covered in ASN profile stack).

## Recommended additional E2E (no overlap with unit/integration)

Unit and integration tests use **mocked** ngx, shared_dict, and dependencies; they assert module logic and handler behaviour. E2E should cover only what **real HTTP + real nginx + real shared_dict** can prove:

| Scenario | Why E2E-only (not duplicated elsewhere) |
|----------|----------------------------------------|
| **Token bucket exhaustion** | Send many `POST /v1/decision` with the same limit key (e.g. same JWT `org_id`) until one request returns **429**. Assert response has `X-Fairvisor-Reason`, `Retry-After`. Unit tests token_bucket with a mock dict; only E2E has real `incr`/`get` across requests. |
| **503 when no bundle** | Start Edge with no policy file or invalid bundle; `POST /v1/decision` returns **503**. Unit/integration mock "no bundle"; E2E proves init_worker didn’t apply and the real access path returns 503. |
| **Reject headers on the wire** | One request that gets 429 returns headers `X-Fairvisor-Reason`, `Retry-After`, `RateLimit`, `RateLimit-Reset` to the client. Integration checks the handler sets them; E2E checks they are actually sent over HTTP. |
| **Debug-session headers** | `POST /v1/debug/session` with debug secret enables `X-Fairvisor-Debug-*` headers (including policy/rule attribution); `POST /v1/debug/logout` disables them. |
| **SIGHUP policy reload** | Replace policy file in the container, send `SIGHUP`, send a request that would be rejected by the old policy but allowed by the new one (or vice versa). No unit/integration equivalent; pure lifecycle. |
| **Container exit when required env missing** | **Standalone:** only `FAIRVISOR_CONFIG_FILE` is required (no `FAIRVISOR_EDGE_ID`). **SaaS:** `FAIRVISOR_EDGE_ID`, `FAIRVISOR_EDGE_TOKEN`, `FAIRVISOR_SAAS_URL`. Missing required vars for the chosen mode → non-zero exit. |
| **Concurrent requests / contention** | Several concurrent `POST /v1/decision` with the same limit key; assert at least one 429. Validates real shared_dict contention. |

Health and “POST /v1/decision with headers returns 200” are already covered. The rows above are additive and do not repeat unit/integration scenarios.
