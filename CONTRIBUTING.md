# Contributing to Fairvisor Edge

Thanks for contributing.

## Ground Rules

- All contributions are licensed under MPL-2.0.
- By submitting code, docs, or tests, you agree to license your contribution under MPL-2.0.
- Keep changes small, reviewable, and test-backed.
- For bug fixes: each fix must include or update a test that would fail before the fix.

## Development Prerequisites

- OpenResty (`resty`) in PATH
- LuaJIT 2.1+
- Python 3.12+ (for E2E tests)
- Docker (for E2E)

## Local Validation

Run before opening a PR:

```bash
luacheck src/ cli/ spec/ --std luajit --globals ngx --no-unused-args --max-line-length 120
busted spec/unit/
busted spec/integration/
pytest tests/e2e -v
```

If your change does not affect E2E behavior, still run at least unit/integration suites.

## CI Workflows

- `.github/workflows/ci.yml` runs on PRs and pushes to `master`:
  - `luacheck`
  - unit tests (`busted spec/unit/`)
  - integration tests (`busted spec/integration/`)
  - quality checks (JSON validity, docs path sanity, changelog `[Unreleased]`)
- `.github/workflows/release.yml` runs on release tags (`vMAJOR.MINOR.PATCH`):
  - changelog version presence check
  - full Lua suite (`busted spec/`)
  - Docker E2E suite (`pytest tests/e2e -v`)

## Style and Architecture

Follow project conventions from:

- `AGENTS.md`
- `constitution.md`

Key expectations:

- Lua code style and module boundaries are mandatory.
- No global state except `ngx`.
- Deterministic rule behavior for the same input.

## Pull Request Process

1. Open or link an issue describing the problem.
2. Create a branch from `master` and implement a focused change.
3. Add/update tests.
4. Fill in the PR template completely.
5. Address review feedback with additional tests where needed.

## Commit Guidance

- Prefer small atomic commits.
- Explain behavior changes, not only code movement.
- Reference issue IDs in commit messages when relevant.

## Reporting Security Issues

Do not open public issues for vulnerabilities.

Use `SECURITY.md` disclosure flow.
