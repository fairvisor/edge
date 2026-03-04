# Spec — Lua Test Layout

Unit and integration tests use **busted** with a Gherkin-style runner (`spec/helpers/gherkin.lua`). Scenarios are split into **feature files** (Gherkin text) and **spec files** (step definitions and harness).

## Layout convention

For each module tested with BDD:

| What | Where |
|------|--------|
| Scenarios (Feature / Rule / Scenario) | `spec/<layer>/features/<module>.feature` |
| Step definitions + harness | `spec/<layer>/<module>_spec.lua` |

`<layer>` is `unit` or `integration`. The spec file loads the feature via:

```lua
runner:feature_file_relative("features/<module>.feature")
```

Path is relative to the spec file directory, so `features/` sits next to the `*_spec.lua` file (e.g. `spec/unit/features/shadow_mode.feature` for `spec/unit/shadow_mode_spec.lua`).

## Structure

- **`spec/unit/`** — unit tests; one module in isolation, mocked ngx.
- **`spec/integration/`** — integration tests; module interactions, realistic flows.
- **`spec/helpers/`** — shared runner and mocks:
  - `gherkin.lua` — parses Gherkin, runs scenarios; provides `feature_file_relative(rel_path)` to load a `.feature` file.
  - `mock_ngx.lua` — ngx/shared_dict/time mocks per AGENTS.md.

## Reference

- **AGENTS.md** — Testing Conventions (Article VIII), BDD naming, mock patterns.
- **constitution.md** — Article VIII (Testing Philosophy), golden tests.
