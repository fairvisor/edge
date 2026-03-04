# Decision API Reference

## Endpoint

- Method: `POST`
- Canonical path: `/v1/decision`
- Debug session endpoints:
  - `POST /v1/debug/session` (requires `X-Fairvisor-Debug-Secret`)
  - `POST /v1/debug/logout`

## Request Contract

### Required headers (decision_service mode)

- `X-Original-Method`
- `X-Original-URI`

### Optional headers

- `Authorization` (`Bearer <jwt>`) for claim extraction
- Any headers used by descriptors/rules (`header:*` limit keys)

### Request body

- Current endpoint logic does not require a body for decisioning.

## Response Status Codes

| Status | Meaning |
|---|---|
| `200` | Request allowed (including shadow-mode and throttled-then-allowed flows). |
| `429` | Request rejected by policy logic. |
| `503` | Edge cannot evaluate (e.g. bundle missing or dependency unavailable). |

## Runtime endpoints

- `GET /livez` -> liveness (`200`)
- `GET /readyz` -> readiness (`200` with loaded bundle, `503` when no bundle is loaded)
- `GET /metrics` -> Prometheus metrics

## Response Body

- Response body is not part of the public contract.
- Integrations must rely on status code and headers only.
- Current implementation returns an empty body on the allow path; reject/error body remains implementation-dependent.

## Response Headers

### Common rate limit headers

| Header | When present | Meaning |
|---|---|---|
| `RateLimit-Limit` | If limiter returns a limit value | Total limit for current key/window. |
| `RateLimit-Remaining` | If limiter returns remaining value | Remaining budget/tokens. |
| `RateLimit-Reset` | If limiter returns reset or retry window | Seconds to reset/retry horizon. |
| `RateLimit` | If limiter metadata exists | Structured header: `"policy";r=<remaining>;t=<reset>`. |

### Fairvisor headers

| Header | When present | Meaning |
|---|---|---|
| `X-Fairvisor-Reason` | Reject decisions | Reject reason code. |
| `Retry-After` | Reject decisions | Retry delay in seconds; deterministic per client, different for different users, not configurable. |
| `X-Fairvisor-Warning` | Loop/cost warning paths | Advisory signal for non-reject escalation. |
| `X-Fairvisor-Loop-Count` | Loop detection details | Observed loop count metadata. |

### Debug-session headers

When request carries a valid debug cookie (`fv_dbg`), responses also include verbose
`X-Fairvisor-Debug-*` headers, including policy and rule attribution:

- `X-Fairvisor-Debug-Policy`
- `X-Fairvisor-Debug-Rule`
- `X-Fairvisor-Debug-Decision`
- `X-Fairvisor-Debug-Mode`
- `X-Fairvisor-Debug-Reason`
- `X-Fairvisor-Debug-Latency-Us`

## Decision Flow Notes

- `kill_switch` is evaluated before normal rule checks.
- In `shadow` mode, would-reject decisions are converted to allow and exposed via metadata/logs.
- `throttle` action sleeps (`delay_ms`) and then continues as allow.

## Retry-After Jitter

Applied on reject responses to reduce synchronized retries. The value is **deterministic per client** (same identity + same decision → same value; different users get different values), so retries are spread across clients. Jitter is **not configurable** — no environment variables; behaviour is fixed.

## Mode-Specific Request Context

- `decision_service`: method/path are taken from `X-Original-Method` and `X-Original-URI` when present.
- `reverse_proxy`: method/path are taken from nginx request (`$request_method`, `$uri`).
