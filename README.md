<p align="center">
  <a href="https://fairvisor.com">
    <img src="https://fairvisor.com/logo.svg" alt="Fairvisor" height="48" />
  </a>
</p>

<h3 align="center">Turn API limits into enforceable business policy.</h3>

<p align="center">
  Open-source edge enforcement engine for rate limits, quotas, and cost budgets.<br>
  Runs standalone or with a SaaS control plane for team governance.
</p>

<p align="center">
  <a href="https://github.com/fairvisor/fairvisor-edge/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MPL--2.0-blue" alt="License: MPL-2.0"></a>
  <a href="https://github.com/fairvisor/fairvisor-edge/releases"><img src="https://img.shields.io/github/v/release/fairvisor/fairvisor-edge" alt="Latest release"></a>
  <a href="https://github.com/fairvisor/fairvisor-edge/actions"><img src="https://img.shields.io/github/actions/workflow/status/fairvisor/fairvisor-edge/ci.yml?label=CI" alt="CI"></a>
  <a href="https://github.com/fairvisor/fairvisor-edge/pkgs/container/fairvisor-edge"><img src="https://img.shields.io/badge/ghcr.io-fairvisor--edge-blue?logo=docker" alt="GHCR image"></a>
  <img src="https://img.shields.io/badge/platform-linux%2Famd64%20·%20linux%2Farm64-lightgrey" alt="Platforms: linux/amd64 · linux/arm64">
  <a href="https://docs.fairvisor.com/docs/quickstart/"><img src="https://img.shields.io/badge/docs-quickstart-informational" alt="Docs"></a>
</p>

<p align="center">
  <b>Sub-ms median · p99 &lt; 1ms · No Redis · No database</b>
</p>

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

Results at 10,000 RPS steady state (c6i.xlarge, 4 vCPU):

| Percentile | Decision service | Reverse proxy | Raw nginx (baseline) |
|---|---|---|---|
| p50 | 68 μs | 142 μs | 78 μs |
| p90 | 95 μs | 198 μs | 112 μs |
| p99 | 280 μs | 520 μs | 310 μs |
| p99.9 | 1.2 ms | 2.8 ms | 1.5 ms |

Max sustained throughput (single instance):

| Configuration | Max RPS |
|---|---|
| Simple rate limit (1 rule) | 85,000 |
| Complex policy (5 rules, JWT parsing, loop detection) | 52,000 |
| With token estimation (tiktoken) | 38,000 |

**No external datastore.** All enforcement state lives in in-process shared memory (`ngx.shared.dict`). No Redis, no Postgres, no network round-trips in the decision path.

> Reproduce: `git clone https://github.com/fairvisor/benchmarks && cd benchmarks && ./run-all.sh`

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
