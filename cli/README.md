# Fairvisor CLI

Command-line tool for scaffolding policies, validating configs, dry-run testing, and SaaS connection setup. Written in Lua; runs via OpenResty's `resty` and reuses the same `fairvisor.*` modules as the edge (validate/test behaviour matches production).

## Prerequisites

- **OpenResty** (or a Lua 5.1+ environment with `resty`). The `resty` CLI must be in your `PATH`.
- For `connect`: network access to the SaaS API.

## Run

From the repo root:

```bash
./bin/fairvisor <command> [options]
```

Or with `resty` directly (e.g. from another directory, adjusting `-I` paths):

```bash
resty -I /path/to/fv-oss/src -I /path/to/fv-oss/cli /path/to/fv-oss/cli/main.lua <command> [options]
```

`bin/fairvisor` sets `-I` to the repo's `src` and `cli` so that `require("cli.commands.init")` and `require("fairvisor.bundle_loader")` resolve correctly.

## Commands

| Command | Description |
|--------|-------------|
| `fairvisor init [--template=api\|llm\|webhook]` | Generate `policy.json` and `edge.env.example` in the current directory. |
| `fairvisor validate <file\|->` | Validate policy JSON; exit 0 if valid, non-zero with errors otherwise. |
| `fairvisor test <file> [--requests=<file>] [--format=table\|json]` | Dry-run mock requests through the rule engine. |
| `fairvisor connect [--token=TOKEN] [--url=URL] [--output=PATH]` | Write credentials, verify SaaS connection, optionally download initial bundle. |
| `fairvisor status [--edge-url=URL] [--format=table\|json]` | Show policy version, SaaS connection, counters. |
| `fairvisor logs [--action=ACTION] [--reason=REASON]` | Stream structured logs with optional filters. |
| `fairvisor version` | Print CLI version. |
| `fairvisor help` | Print command list and usage. |

## Examples

```bash
fairvisor init
fairvisor init --template=llm
fairvisor validate policy.json
fairvisor test policy.json
fairvisor connect --token=eyJ...
fairvisor version
fairvisor help
```

## Tests

Unit tests for CLI commands live in `spec/unit/cli/`. Run with busted from the repo root (same as other Lua specs).
