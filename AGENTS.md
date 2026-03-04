# AGENTS.md — Fairvisor Edge Project Context

> This file provides AI coding agents with the essential project context needed
> to implement any feature autonomously. Read this once before starting work.
> For per-feature details, see the Feature Implementation Brief in the issue body.

---

## Runtime Identity

Fairvisor Edge is an **inline HTTP enforcement layer** built on **OpenResty / LuaJIT 2.1+**.
It makes allow/reject decisions on every request with sub-millisecond latency.
It is NOT a proxy, NOT a gateway, NOT a WAF — it is a **policy enforcement point**.

- Only runtime language: **Lua** (LuaJIT 2.1+ on OpenResty)
- Runs as an **nginx module** inside nginx phases: `init_worker`, `access`, `header_filter`, `body_filter`, `log`
- Performance-critical paths MAY use LuaJIT FFI for C libraries (only when profiling proves necessity)

---

## Code Style (Article IX)

- **2-space indentation**
- **`snake_case`** for variables, functions, file names
- **`UPPER_CASE`** for module-level constants
- **`local` everything** — no globals except `ngx`
- **One `return`** at module bottom exporting the public API
- **`_` prefix** for private/internal functions (MUST NOT be called from outside the module)
- **Comments:** explain *why*, not *what*. No commented-out code.

---

## Error Handling (Article IX §9.3)

- Return `nil, error_message` from functions — **never `error()` in production code**
- Log errors with context: include `module`, `function`, and relevant IDs
- Reserve `error()` for programming bugs / assertions during development only

---

## File Layout (Article IX §9.2)

```
bin/
  fairvisor                 -- CLI entrypoint (requires OpenResty resty in PATH)
cli/
  main.lua                  -- command dispatch
  commands/                 -- init, validate, test, connect, status, logs, version, help
  lib/                      -- args, output
  templates/                -- api.json, llm.json, webhook.json
src/
  fairvisor/
    descriptor.lua          -- 001
    bundle_loader.lua       -- 002
    ...
spec/
  unit/
    <module>_spec.lua       -- one per module
    cli/                    -- help_spec, version_spec, init_spec, ...
  integration/
  helpers/
    mock_ngx.lua
tests/
  e2e/
  docker-compose.test.yml
```

CLI runs as Lua via OpenResty's `resty`; it reuses `fairvisor.*` modules for validate/test (no second language).

---

## Performance Invariants (Article II)

These MUST be respected in every module:

1. **Zero allocations on hot path** — no `string.format`, no table creation, no closures, no JSON per request
2. **No I/O in the decision path** — no disk, no network, no DNS
3. **No regex on hot path** — use radix trie for routes, direct table lookups for claims
4. **`shared_dict` budget:** at most `1 get + 1 set` per enforced token bucket per request
5. **Prepare at load, execute at request** — build data structures during `init_worker` or hot-reload

### Latency Budgets (p50 targets)

| Component | p50 | p99 max |
|-----------|-----|---------|
| Route/policy selection (LRU hit) | < 5 µs | — |
| Route/policy selection (LRU miss) | < 50 µs | — |
| Descriptor extraction (≤3 keys) | < 20 µs | — |
| Token bucket (low contention) | < 50 µs | < 500 µs |
| Full rule evaluation (≤10 policies × 10 rules) | < 100 µs | < 500 µs |
| **Total per-request** | **< 100 µs** | **< 1 ms** |

---

## Module Architecture (Article V)

### Dependency Graph

```
bundle_loader → route_index, policy_store
decision_api  → rule_engine
rule_engine   → descriptor_extraction
              → route_matching
              → token_bucket / cost_budget / llm_limiter
              → loop_detection
              → circuit_breaker
              → kill_switch
              → shadow_mode
```

### Rules

- **One module, one responsibility** — each feature spec (001–018) maps to one Lua module
- **No circular dependencies** — if A requires B, B MUST NOT require A
- **No relative imports** — all modules loaded via `require("fairvisor.<module>")`
- **Interfaces over internals** — expose public API per spec; `_` prefix for private functions

---

## Correctness Model (Article IV)

- **"All must pass"** — a request must pass ALL rules in ALL matching policies. First REJECT stops evaluation.
- **Deterministic** — same input → same output. No randomness, no jitter.
- **Fail-open** for missing descriptors — allow request, log `reason=descriptor_missing`, increment metric.
- **Kill-switch before rules** — always runs first; if matched, REJECT with `reason: "kill_switch"`.
- **Shadow mode is transparent** — logs decision but always returns ALLOW.

---

## Testing Conventions (Article VIII)

### Framework & Style

- **busted** for Lua tests (BDD style)
- **All tests MUST be Gherkin-first**: express scenarios in plain English using `Feature/Rule/Scenario/Given/When/Then/And`
- **pytest** for e2e tests; E2E scenarios MUST also be Gherkin-first in plain English
- **Test-to-code ratio: > 2:1** (lines of test ≥ 2× lines of production code)

### Three Mandatory Layers

| Layer | Location | What | Runs without nginx? |
|-------|----------|------|-------------------|
| Unit | `spec/unit/` | Every module in isolation, mock ngx APIs | Yes |
| Integration | `spec/integration/` | Module interactions, realistic bundles | Yes |
| E2E | `tests/e2e/` | Real OpenResty in Docker, real HTTP | No |

### BDD Naming

Use natural English. Gherkin blocks via the local wrapper are mandatory for test scenarios, including `tests/e2e`.

**Feature files vs spec:** Scenarios live in `spec/<layer>/features/<module>.feature`; step definitions and harness in `spec/<layer>/<module>_spec.lua`. The spec loads the feature with `runner:feature_file_relative("features/<module>.feature")`. See `spec/README.md` for the full layout convention.

```gherkin
Feature: Token bucket enforcement
  Rule: Requests cannot exceed burst capacity
    Scenario: Request is rejected when bucket is empty
      Given the nginx mock environment is reset
      When I run one request with key "tb:rule:user-1" and default cost
      Then the request is rejected
```

```lua
-- GOOD
describe("token bucket rate limiter", function()
  context("when the bucket is full", function()
    it("allows the request and decrements tokens", function()

-- BAD
describe("tb", function()
  it("test1", function()
```

### Golden Tests

Golden test scenarios (RE-001 through RE-014) are sacred — they MUST ALL pass at every commit.

---

## ngx Mock Patterns

**Critical: agents MUST use these patterns to mock nginx APIs in unit tests.**

### shared_dict Mock

```lua
local function mock_shared_dict()
  local data = {}
  return {
    get = function(_, key)
      return data[key]
    end,
    set = function(_, key, value)
      data[key] = value
      return true
    end,
    incr = function(_, key, value, init, init_ttl)
      local current = data[key]
      if current == nil then
        if init then
          data[key] = init + value
          return data[key], nil, true  -- value, err, forcible
        end
        return nil, "not found"
      end
      data[key] = current + value
      return data[key], nil, false
    end,
    delete = function(_, key)
      data[key] = nil
    end,
    flush_all = function(_)
      data = {}
    end,
  }
end
```

### ngx.now() Mock

```lua
local _mock_time = 1000.000

_G.ngx = _G.ngx or {}
ngx.now = function() return _mock_time end
ngx.update_time = function() end

-- Advance time in tests:
local function advance_time(seconds)
  _mock_time = _mock_time + seconds
end
```

### ngx.shared Mock (registry)

```lua
ngx.shared = ngx.shared or {}
ngx.shared.fairvisor_counters = mock_shared_dict()
```

---

## Stub Convention

When implementing a feature whose dependencies are not yet implemented:

1. Create a **stub module** with the interface defined in the dependency's spec
2. Place stubs in `src/fairvisor/` with the standard module name
3. The stub MUST implement the public API contract (correct signatures)
4. The stub SHOULD return sensible defaults (e.g., extracted descriptors = empty table)
5. Mark stub functions with a comment: `-- STUB: replace when <feature> is implemented`

---

## Dependency Wave Order

Features should be implemented in this order:

| Wave | Features | Dependencies |
|------|----------|-------------|
| 1 | 001, 003, 004, 005, 007, 008, 009, 010, 012 | None (leaf modules) |
| 2 | 002, 013 | 001 |
| 3 | 006 | 001, 003, 004, 005, 007, 008, 009, 010 |
| 4 | 011, 014, 015 | 006 |
| 5 | 016, 017, 018 | 002, 011, 012 |

Within a wave, features can be implemented in parallel.
