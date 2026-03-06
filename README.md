<p align="center">
  <a href="https://fairvisor.com">
    <img src="https://fairvisor.com/logo.svg" alt="Fairvisor" height="48" />
  </a>
</p>

<h3 align="center">Turn API limits into enforceable business policy.</h3>

<p align="center">
  Every API that charges per token, serves paying tenants, or runs agentic pipelines needs<br>
  enforceable limits — not just rate-limit middleware bolted on as an afterthought.<br>
  <br>
  Open-source edge enforcement engine for rate limits, quotas, and cost budgets.<br>
  Runs standalone or with a SaaS control plane for team governance.
</p>

<p align="center">
  <a href="https://github.com/fairvisor/edge/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MPL--2.0-blue" alt="License: MPL-2.0"></a>
  <a href="https://github.com/fairvisor/edge/releases"><img src="https://img.shields.io/github/v/release/fairvisor/edge" alt="Latest release"></a>
  <a href="https://github.com/fairvisor/-edge/actions"><img src="https://img.shields.io/github/actions/workflow/status/fairvisor/edge/ci.yml?label=CI" alt="CI"></a>
  <a href="https://github.com/fairvisor/edge/pkgs/container/fairvisor-edge"><img src="https://img.shields.io/badge/ghcr.io-fairvisor--edge-blue?logo=docker" alt="GHCR image"></a>
  <img src="https://img.shields.io/badge/platform-linux%2Famd64%20·%20linux%2Farm64-lightgrey" alt="Platforms: linux/amd64 · linux/arm64">
  <a href="https://docs.fairvisor.com/docs/quickstart/"><img src="https://img.shields.io/badge/docs-quickstart-informational" alt="Docs"></a>
</p>

<p align="center">
  <b>Latency: median 112 μs, p99 &lt; 1 ms · No external state (no Redis / DB)</b>
</p>

---

## Table of Contents

- [What is Fairvisor?](#what-is-fairvisor)
- [Why not nginx / Kong / Envoy?](#why-not-nginx--kong--envoy)
- [Quick start](#quick-start)
- [LLM token budget in 30 seconds](#llm-token-budget-in-30-seconds)
- [How a request flows](#how-a-request-flows)
- [Enforcement capabilities](#enforcement-capabilities)
- [Policy as code](#policy-as-code)
- [Performance](#performance)
- [Deployment](#deployment)
- [CLI](#cli)
- [SaaS control plane (optional)](#saas-control-plane-optional)
- [Project layout](#project-layout)
- [Contributing](#contributing)
- [License](#license)

---

## What is Fairvisor?

Fairvisor Edge is a **policy enforcement layer** that sits between your API gateway and your upstream services. Every request is evaluated against a declarative JSON policy bundle and receives a deterministic allow or reject verdict — with machine-readable rejection headers and sub-millisecond latency.

It is **not** a reverse proxy replacement. It is **not** a WAF. It is a dedicated, composable enforcement point for:

- **Rate limits and quotas** — per route, per tenant, per JWT claim, per API key
- **Cost budgets** — cumulative spend caps per org, team, or endpoint
- **LLM token limits** — TPM/TPD budgets with pre-request reservation and post-response refund
- **Kill switches** — instant traffic blocking per descriptor, no restart required
- **Shadow mode** — dry-run enforcement against real traffic before going live
- **Loop detection** — stops runaway agentic workflows at the edge
- **Circuit breaker** — auto-trips on spend spikes, auto-resets after cooldown

All controls are defined in one versioned policy bundle. Policies hot-reload without restarting the process.

## Why not nginx / Kong / Envoy?

If you have an existing gateway, the question is whether Fairvisor adds anything you can't get from the plugin ecosystem already installed. Here is the honest comparison:

| Concern | nginx `limit_req` | Kong rate-limiting | Envoy global rate limit | Fairvisor Edge |
|---|---|---|---|---|
| Per-tenant limits (JWT claim) | No — IP/zone only | Partial — custom plugin | Yes, via descriptors | Yes — `jwt:org_id`, `jwt:plan`, any claim |
| LLM token budgets (TPM/TPD) | No | No | No | Yes — pre-request reservation + post-response refund |
| Cost budgets (cumulative $) | No | No | No | Yes |
| Distributed state requirement | No (per-process) | Redis or Postgres | Separate rate limit service | No — in-process `ngx.shared.dict` |
| Network round-trip in hot path | No | Yes (to Redis) | Yes (to rate limit service) | No |
| Policy as versioned JSON | No | No (Admin API state) | Partial (Envoy config) | Yes — commit, diff, roll back |
| Kill switches (instant, no restart) | No | No | No | Yes |
| Loop detection for agents | No | No | No | Yes |

**If nginx `limit_req` is enough for you**, use it. It has zero overhead and is the right tool for simple per-IP global throttling. Fairvisor becomes relevant when you need per-tenant awareness, JWT-claim-based bucketing, or cost/token tracking that `limit_req` has no model for.

**If you are already running Kong**, the built-in rate limiting plugin stores counters in Redis or Postgres — every decision is a network call. Fairvisor can run alongside Kong as an `auth_request` decision service with no external state.

**If you are running Envoy**, the [global rate limit service](https://github.com/envoyproxy/ratelimit) requires deploying a separate Redis-backed service with its own config language. Fairvisor is one container, one JSON file, and integrates via `ext_authz` in the same position.

**If you are on Cloudflare or Akamai**, per-JWT-claim limits, LLM token budgets, and cost caps are not in the platform's model. If your limits are tenant-aware or cost-aware, you need something that runs in your own stack.

Fairvisor integrates *alongside* Kong, nginx, and Envoy — it is not a replacement. See [docs/gateway-integration.md](docs/gateway-integration.md) for integration patterns.

## Quick start

### 1. Create a policy

```bash
mkdir fairvisor-demo && cd fairvisor-demo
```

`policy.json`:

```json
{
  "bundle_version": 1,
  "issued_at": "2026-01-01T00:00:00Z",
  "policies": [
    {
      "id": "demo-rate-limit",
      "spec": {
        "selector": { "pathPrefix": "/", "methods": ["GET", "POST"] },
        "mode": "enforce",
        "rules": [
          {
            "name": "global-rps",
            "limit_keys": ["ip:address"],
            "algorithm": "token_bucket",
            "algorithm_config": { "tokens_per_second": 5, "burst": 10 }
          }
        ]
      }
    }
  ],
  "kill_switches": []
}
```

### 2. Run the edge

```bash
docker run -d \
  --name fairvisor \
  -p 8080:8080 \
  -v "$(pwd)/policy.json:/etc/fairvisor/policy.json:ro" \
  -e FAIRVISOR_CONFIG_FILE=/etc/fairvisor/policy.json \
  -e FAIRVISOR_MODE=decision_service \
  ghcr.io/fairvisor/fairvisor-edge:v0.1.0
```

### 3. Verify

```bash
curl -sf http://localhost:8080/readyz
# {"status":"ok"}

curl -s -w "\nHTTP %{http_code}\n" \
  -H "X-Original-Method: GET" \
  -H "X-Original-URI: /api/data" \
  -H "X-Forwarded-For: 10.0.0.1" \
  http://localhost:8080/v1/decision
```

> Full walkthrough: [docs.fairvisor.com/docs/quickstart](https://docs.fairvisor.com/docs/quickstart/)

## LLM token budget in 30 seconds

```json
{
  "id": "llm-budget",
  "spec": {
    "selector": { "pathPrefix": "/v1/chat" },
    "mode": "enforce",
    "rules": [
      {
        "name": "per-org-tpm",
        "limit_keys": ["jwt:org_id"],
        "algorithm": "token_bucket_llm",
        "algorithm_config": {
          "tokens_per_minute": 60000,
          "tokens_per_day": 1200000,
          "default_max_completion": 800
        }
      }
    ]
  }
}
```

Each organization (from the JWT `org_id` claim) gets its own independent 60k TPM / 1.2M TPD budget. Requests over the limit return a `429` with an OpenAI-compatible error body — no client changes needed.

Works with OpenAI, Anthropic, Azure OpenAI, Mistral, and any OpenAI-compatible endpoint.

## How a request flows

**Decision service mode** — Fairvisor runs as a sidecar. Your existing gateway calls `/v1/decision` via `auth_request` (nginx) or `ext_authz` (Envoy) and handles forwarding itself.

**Reverse proxy mode** — Fairvisor sits inline. Traffic arrives at Fairvisor directly, gets evaluated, and is proxied to the upstream if allowed. No separate gateway needed.

Both modes use the same policy bundle and return the same rejection headers.

When a request is rejected:

```http
HTTP/1.1 429 Too Many Requests
X-Fairvisor-Reason: tpm_exceeded
Retry-After: 12
RateLimit: "llm-default";r=0;t=12
RateLimit-Limit: 120000
RateLimit-Remaining: 0
RateLimit-Reset: 12
```

Headers follow [RFC 9333 RateLimit Fields](https://www.rfc-editor.org/rfc/rfc9333). `X-Fairvisor-Reason` gives clients a machine-readable code for retry logic and observability.

### Architecture

**Decision service mode** (sidecar — your gateway calls `/v1/decision`, handles forwarding itself):

```
 Client ──► Your gateway (nginx / Envoy / Kong)
                  │
                  │  POST /v1/decision
                  │  (auth_request / ext_authz)
                  ▼
          ┌─────────────────────┐
          │   Fairvisor Edge    │
          │  decision_service   │
          │                     │
          │  rule_engine        │
          │  ngx.shared.dict    │  ◄── no Redis, no network
          └──────────┬──────────┘
                     │
          204 allow  │  429 reject
                     ▼
          gateway proxies or returns rejection
```

**Reverse proxy mode** (inline — Fairvisor handles proxying):

```
 Client ──► Fairvisor Edge (reverse_proxy)
                  │
                  │  access.lua → rule_engine
                  │  ngx.shared.dict
                  │
          allow ──► upstream service
          reject ──► 429 + RFC 9333 headers
```

Both modes use the same policy bundle and produce the same rejection headers.

## Enforcement capabilities

| If you need to… | Algorithm | Typical identity keys | Reject reason |
|---|---|---|---|
| Cap request frequency | `token_bucket` | `jwt:user_id`, `header:x-api-key`, `ip:addr` | `rate_limit_exceeded` |
| Cap cumulative spend | `cost_based` | `jwt:org_id`, `jwt:plan` | `budget_exhausted` |
| Cap LLM tokens (TPM/TPD) | `token_bucket_llm` | `jwt:org_id`, `jwt:user_id` | `tpm_exceeded`, `tpd_exceeded` |
| Instantly block a segment | kill switch | any descriptor | `kill_switch_active` |
| Dry-run before enforcing | shadow mode | any descriptor | allow + `would_reject` telemetry |
| Stop runaway agent loops | loop detection | request fingerprint | `loop_detected` |
| Clamp spend spikes | circuit breaker | global or policy scope | `circuit_breaker_open` |

Identity keys can be **JWT claims** (`jwt:org_id`, `jwt:plan`), **HTTP headers** (`header:x-api-key`), or **IP attributes** (`ip:addr`, `ip:country`). Combine multiple keys per rule for compound matching.

## Policy as code

Define policies in JSON, validate against the schema, test in shadow mode, then promote:

```bash
# Validate bundle structure and rule semantics
fairvisor validate ./policies.json

# Replay real traffic without blocking anything
fairvisor test --dry-run

# Apply a new bundle (hot-reload, no restart)
fairvisor connect --push ./policies.json
```

Policies are versioned JSON — commit them to Git, review changes in PRs, roll back with confidence.

## Performance

### Benchmark methodology (March 4, 2026)

- **Host:** AWS `c7i.2xlarge` (8 vCPU, 16 GiB RAM)
- **OS:** Ubuntu 24.04.3 LTS
- **Runtime:** OpenResty 1.29.2.1, Fairvisor latest `main` (no Docker)
- **Load tool:** `k6` v0.54.0, `constant-arrival-rate`, 10,000 RPS for 60s, 10s warmup
- **Benchmark script:** `run-all.sh` from `fairvisor/benchmark`
- **CPU isolation (single-host run):** `taskset` split
  - OpenResty/backend on cores `0-3`
  - k6 on cores `4-7`
- **Decision endpoint contract:** `POST /v1/decision` with `X-Original-Method` and `X-Original-URI`
- **Note:** reverse proxy numbers include policy evaluation and upstream proxy hop to backend nginx.

### Latest measured latency @ 10,000 RPS

| Percentile | Decision service | Reverse proxy | Raw nginx (baseline) |
|---|---|---|---|
| p50 | 112 μs | 241 μs | 71 μs |
| p90 | 191 μs | 376 μs | 190 μs |
| p99 | 426 μs | 822 μs | 446 μs |
| p99.9 | 2.99 ms | 2.98 ms | 1.61 ms |

### Latest max sustained throughput (single instance)

| Configuration | Max RPS |
|---|---|
| Simple rate limit (1 rule) | 110,500 |
| Complex policy (5 rules, JWT parsing, loop detection) | 67,600 |
| With token estimation | 49,400 |

**No external datastore.** All enforcement state lives in in-process shared memory (`ngx.shared.dict`). No Redis, no Postgres, no network round-trips in the decision path.

> Reproduce: `git clone https://github.com/fairvisor/benchmark && cd benchmark && ./run-all.sh`

## Deployment

| Target | Guide |
|---|---|
| Docker (local/VM) | [docs/guides/docker](https://docs.fairvisor.com/docs/guides/docker/) |
| Kubernetes (Helm) | [docs/guides/helm](https://docs.fairvisor.com/docs/guides/helm/) |
| LiteLLM integration | [docs/guides/litellm](https://docs.fairvisor.com/docs/guides/litellm/) |
| nginx `auth_request` | [docs/gateway/nginx](https://docs.fairvisor.com/docs/gateway/nginx/) |
| Envoy `ext_authz` | [docs/gateway/envoy](https://docs.fairvisor.com/docs/gateway/envoy/) |
| Kong / Traefik | [docs/gateway](https://docs.fairvisor.com/docs/gateway/) |

Fairvisor integrates **alongside** Kong, nginx, Envoy, and Traefik — it does not replace them.

## CLI

```bash
fairvisor init --template=api    # scaffold a policy bundle
fairvisor validate policy.json   # validate before deploying
fairvisor test --dry-run         # shadow-mode replay
fairvisor status                 # edge health and loaded bundle info
fairvisor logs                   # tail rejection events
fairvisor connect                # connect to SaaS control plane
```

## SaaS control plane (optional)

The edge is open source and runs standalone. The SaaS adds:

- Policy editor with validation and diff view
- Fleet management and policy push
- Analytics: top limited routes, tenants, abusive sources
- Audit log exports for SOC 2 workflows
- Alerts (Datadog, Sentry, PagerDuty, Prometheus)
- RBAC and SSO (Enterprise)

If the SaaS is unreachable, the edge keeps enforcing with the last-known policy bundle. No degradation.

[fairvisor.com/pricing](https://fairvisor.com/pricing/)

## Project layout

```
src/fairvisor/    runtime modules (OpenResty/LuaJIT)
cli/              command-line tooling
spec/             unit and integration tests (busted)
tests/e2e/        Docker-based E2E tests (pytest)
examples/         sample policy bundles
helm/             Helm chart
docker/           Docker artifacts
docs/             reference documentation
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports, issues, and pull requests welcome.

Run the test suite:

```bash
busted spec          # unit + integration
pytest tests/e2e -v  # E2E (requires Docker)
```

## License

[Mozilla Public License 2.0](LICENSE)

---

**Docs:** [docs.fairvisor.com](https://docs.fairvisor.com/docs/) · **Website:** [fairvisor.com](https://fairvisor.com) · **Quickstart:** [5 minutes to enforcement](https://docs.fairvisor.com/docs/quickstart/)
