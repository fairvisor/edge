# Policy Bundle Reference

This document describes the canonical Fairvisor policy bundle format used by the runtime loader and rule engine.

Source of truth:

- `src/fairvisor/bundle_loader.lua`
- `src/fairvisor/rule_engine.lua`
- `src/fairvisor/descriptor.lua`
- `src/fairvisor/token_bucket.lua`
- `src/fairvisor/cost_budget.lua`
- `src/fairvisor/llm_limiter.lua`
- `src/fairvisor/kill_switch.lua`
- `src/fairvisor/route_index.lua`

## Canonical Top-Level Schema

| Field | Type | Required | Validation / constraints | Notes |
|---|---|---|---|---|
| `bundle_version` | number | yes | Must be `> 0` | Used for monotonic reload checks (`version_not_monotonic`). |
| `issued_at` | string | no | ISO 8601 UTC timestamp | Optional metadata. |
| `expires_at` | string | no | ISO 8601 UTC timestamp, must be in the future at load time | Expired bundle is rejected (`bundle_expired`). |
| `policies` | array | yes | Must be a table/array | Each item is validated policy object. |
| `kill_switches` | array | no | Validated by kill switch validator | Evaluated before normal rule processing. |
| `global_shadow` | object | no | Runtime override block with TTL validation | When active, all policies execute in shadow semantics. |
| `kill_switch_override` | object | no | Runtime override block with TTL validation | When active, kill-switch checks are skipped. |
| `defaults` | object | no | No strict schema at load time | Passed through in compiled bundle for future/global defaults. |

## Policy Object (`policies[]`)

| Field | Type | Required | Validation / constraints | Notes |
|---|---|---|---|---|
| `id` | string | yes | Non-empty | Key for `policies_by_id`; should be unique in practice. |
| `spec` | object | yes | Must be table/object | Contains selector, mode, rules, and optional advanced blocks. |

## Policy Spec (`policy.spec`)

| Field | Type | Required | Validation / constraints | Notes |
|---|---|---|---|---|
| `selector` | object | yes | Must be table/object | Route matcher input. |
| `mode` | string | no | `enforce` or `shadow` | If omitted, behavior is effectively enforce. |
| `rules` | array | yes | Must be table/array | Each rule validated. |
| `fallback_limit` | object | no | If provided, validated like a regular rule | Used when no regular rule matches. |
| `loop_detection` | object | no | Consumed by rule engine when `enabled=true` | See advanced blocks below. |
| `circuit_breaker` | object | no | Consumed by rule engine when `enabled=true` | See advanced blocks below. |

## Selector Fields (`policy.spec.selector`)

| Field | Type | Required | Validation / constraints | Match behavior |
|---|---|---|---|---|
| `pathExact` | string | no | Must start with `/` | Exact path match. |
| `pathPrefix` | string | no | Must start with `/` | Prefix match (normalized with trailing `/`, except `/`). |
| `methods` | array of strings | no | Invalid/non-string entries ignored | If absent, any method is allowed. |
| `hosts` | array of strings | no | Non-empty array of hostnames; values normalized to lowercase | If present, selector is applied only for matching host(s). |

Important selector notes:

- A policy must have at least one valid route anchor (`pathExact` or `pathPrefix`) to be indexed.
- Prefix behavior is depth-aware. Example: `/v1/` matches `/v1/x` but not `/v1`.
- Prefix `/` is global and matches all paths.
- Host matching is exact after normalization (case-insensitive, port ignored).

## Rule Fields (`policy.spec.rules[]` and `policy.spec.fallback_limit`)

| Field | Type | Required | Validation / constraints | Notes |
|---|---|---|---|---|
| `name` | string | yes | Non-empty | Used in counters, logs, decision headers. |
| `limit_keys` | array of strings | yes | Must pass descriptor key validation | Defines descriptor extraction and counter partitioning. |
| `algorithm` | string | yes | One of: `token_bucket`, `cost_based`, `token_bucket_llm` | Determines algorithm config schema. |
| `algorithm_config` | object | yes | Must validate for selected algorithm | See algorithm sections below. |
| `match` | object | no | Key/value equality checks | Rule runs only when match conditions are satisfied. |

### `match` semantics

- Keys are descriptor keys (same format as `limit_keys`, e.g. `jwt:plan`, `header:x-tier`).
- Values are compared as string-equivalent.
- For `jwt:*` keys, claims fallback is used when descriptor value is absent.

## Descriptor Keys (`limit_keys` and `match` keys)

Allowed formats:

- `jwt:<name>`
- `header:<name>`
- `query:<name>`
- `ip:address`
- `ip:country`
- `ip:asn`
- `ip:type`
- `ip:tor`
- `ua:bot`
- `ua:bot_category`

`<name>` for `jwt/header/query` must match `[A-Za-z0-9_-]+`.

`ip:type` values are sourced from `ipverse/as-metadata` categories plus Fairvisor enrichment:

- `business`
- `education_research`
- `government_admin`
- `hosting`
- `isp`
- `unrouted` (ASN has no routed prefixes in enrichment datasets)
- `unknown` (default/fallback)

`ip:tor` values are boolean-like selector values from nginx geo classification:

- `true` for Tor exit nodes
- `false` for non-Tor traffic

## Algorithm Config: `token_bucket`

`rule.algorithm = "token_bucket"`

What it is:

- Classic token-bucket rate limiter for request rate control.
- Bucket refills continuously (`tokens_per_second`) up to `burst`.
- Each request consumes cost and is rejected when there are not enough tokens.
- Best for HTTP RPS-style limits with short retry windows.

| Field | Type | Required | Default | Validation / constraints |
|---|---|---|---|---|
| `tokens_per_second` | number | yes* | - | Positive number (`rps` alias supported). |
| `rps` | number | yes* | - | Alias for `tokens_per_second` if `tokens_per_second` absent. |
| `burst` | number | yes | - | Positive, must be `>= tokens_per_second`. |
| `cost_source` | string | no | `fixed` | `fixed`, `header:<name>`, or `query:<name>`. |
| `fixed_cost` | number | no | `1` | Positive number. |
| `default_cost` | number | no | `1` | Positive number. |

`*` At least one of `tokens_per_second` or `rps` is required.

## Algorithm Config: `cost_based`

`rule.algorithm = "cost_based"`

What it is:

- Budget limiter for cumulative spend/cost within a fixed period.
- Uses staged thresholds to escalate actions (`warn` -> `throttle` -> `reject`).
- Best for quota enforcement where each request has variable business cost.

| Field | Type | Required | Default | Validation / constraints |
|---|---|---|---|---|
| `budget` | number | yes | - | Positive number. |
| `period` | string | yes | - | One of: `5m`, `1h`, `1d`, `7d`. |
| `cost_key` | string | no | `fixed` | `fixed`, `header:<name>`, or `query:<name>`. |
| `fixed_cost` | number | conditional | `1` | Required/used for `cost_key=fixed`, positive. |
| `default_cost` | number | no | `1` | Positive number. |
| `staged_actions` | array | yes | - | Non-empty, strict ascending thresholds, must include reject at `100`. |

`staged_actions[]` fields:

| Field | Type | Required | Validation / constraints |
|---|---|---|---|
| `threshold_percent` | number | yes | Between `0` and `100`, strictly ascending globally. |
| `action` | string | yes | One of: `warn`, `throttle`, `reject`. |
| `delay_ms` | number | conditional | Required and `> 0` when `action=throttle`. |

## Algorithm Config: `token_bucket_llm`

`rule.algorithm = "token_bucket_llm"`

What it is:

- Token-aware limiter for LLM traffic.
- Enforces per-minute token budget (TPM) and optional per-day token budget (TPD).
- Estimates prompt/completion token usage per request and rejects on over-budget.
- Best for AI endpoints where request cost is measured in tokens, not request count.

| Field | Type | Required | Default | Validation / constraints |
|---|---|---|---|---|
| `tokens_per_minute` | number | yes | - | Positive number. |
| `tokens_per_day` | number | no | unset | Positive number if set. |
| `burst_tokens` | number | no | `tokens_per_minute` | Positive, must be `>= tokens_per_minute`. |
| `max_tokens_per_request` | number | no | unset | Positive number if set. |
| `max_prompt_tokens` | number | no | unset | Positive number if set. |
| `max_completion_tokens` | number | no | unset | Positive number if set. |
| `default_max_completion` | number | no | `1000` | Positive number. |
| `token_source` | object | no | `{}` | See below. |

`token_source` fields:

| Field | Type | Required | Default | Validation / constraints |
|---|---|---|---|---|
| `estimator` | string | no | `simple_word` | `simple_word` or `header_hint`. |

## Fallback Limit (`policy.spec.fallback_limit`)

- Optional rule-like object used only when no regular rule matches.
- Must have valid `limit_keys`, `algorithm`, and `algorithm_config`.
- `name` is optional; loader supplies `fallback_limit` when omitted.

## Kill Switches (`kill_switches[]`)

Kill switches are evaluated before route/rule processing.

| Field | Type | Required | Validation / constraints | Notes |
|---|---|---|---|---|
| `scope_key` | string | yes | Must match `^(jwt|header|query|ip|ua):[A-Za-z0-9_-]+$` | Descriptor key to compare. |
| `scope_value` | string | yes | Non-empty | Exact match value. |
| `route` | string | no | Non-empty, must start with `/` | If set, requires route equality too. |
| `reason` | string | no | String when set | Stored as kill-switch reason text. |
| `expires_at` | string | no | ISO 8601 UTC | Entry ignored after expiration. |

## Advanced Policy Blocks

These blocks are consumed by `rule_engine` when present.

## Runtime Override Blocks

Top-level runtime overrides are evaluated on every request and auto-deactivate after `expires_at`.

### `global_shadow`

| Field | Type | Required | Validation / constraints |
|---|---|---|---|
| `enabled` | boolean | yes | Must be boolean. |
| `reason` | string | yes when `enabled=true` | Non-empty, max 256 chars. |
| `expires_at` | string | yes when `enabled=true` | ISO 8601 UTC, must be in the future at load time. |

Effect when active:
- All policies are treated as shadow mode at runtime.
- Enforcement actions are converted to allow for client path.
- Client response headers are unchanged; observability is via logs/metrics.

### `kill_switch_override`

| Field | Type | Required | Validation / constraints |
|---|---|---|---|
| `enabled` | boolean | yes | Must be boolean. |
| `reason` | string | yes when `enabled=true` | Non-empty, max 256 chars. |
| `expires_at` | string | yes when `enabled=true` | ISO 8601 UTC, must be in the future at load time. |

Effect when active:
- Kill-switch checks are skipped.
- Client response headers are unchanged; observability is via logs/metrics.

### `policy.spec.loop_detection`

| Field | Type | Required | Default | Validation / constraints |
|---|---|---|---|---|
| `enabled` | boolean | no | false | If false/nil, block is ignored. |
| `window_seconds` | number | yes if enabled | - | Positive integer. |
| `threshold_identical_requests` | number | yes if enabled | - | Positive integer, must be `>= 2`. |
| `action` | string | no | `reject` | One of: `reject`, `throttle`, `warn`. |
| `similarity` | string | no | `exact` | Must be `exact`. |

### `policy.spec.circuit_breaker`

| Field | Type | Required | Default | Validation / constraints |
|---|---|---|---|---|
| `enabled` | boolean | no | false | If false/nil, block is ignored. |
| `spend_rate_threshold_per_minute` | number | yes if enabled | - | Positive number. |
| `action` | string | no | `reject` | Currently only `reject` is valid. |
| `auto_reset_after_minutes` | number | no | `0` | Non-negative number; `0` means no auto reset. |
| `alert` | boolean | no | `false` | Emits alert flag when tripped. |

## Canonical Minimal Example

```json
{
  "bundle_version": 1,
  "issued_at": "2026-01-01T00:00:00Z",
  "expires_at": "2030-01-01T00:00:00Z",
  "policies": [
    {
      "id": "api-default",
      "spec": {
        "selector": {
          "pathPrefix": "/api/",
          "methods": ["GET", "POST"]
        },
        "mode": "enforce",
        "rules": [
          {
            "name": "api-rate-limit",
            "limit_keys": ["header:x-api-key"],
            "algorithm": "token_bucket",
            "algorithm_config": {
              "tokens_per_second": 50,
              "burst": 100
            }
          }
        ]
      }
    }
  ],
  "kill_switches": []
}
```
