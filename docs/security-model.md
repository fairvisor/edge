# Security Model

## Trust Boundaries

1. Upstream gateway/client to Fairvisor Edge
2. Fairvisor Edge runtime to policy bundle data
3. Runtime decision output to downstream services

## Primary Assets

- Policy bundle integrity
- Correct allow/reject decisions
- Descriptor extraction correctness
- Shared dict counter correctness
- Operational logs and metrics integrity

## Threats Considered

- Policy bypass via malformed headers/query values
- Descriptor confusion across naming variants
- Abuse spikes causing synchronized retries
- Misconfiguration causing broad fail-open exposure
- Runtime resource exhaustion on hot path

## Defensive Principles

- Deterministic policy evaluation for equivalent inputs
- Kill-switch checked before normal rule evaluation
- Explicit fail-open semantics only for missing descriptors
- No network/disk I/O in request decision path
- Bounded retries and explicit rejection metadata

## Sensitive Data Handling

- Avoid storing raw credentials in logs.
- Redact or hash sensitive identifiers where feasible.
- Keep token and claim processing minimal and scoped.

## Security Review Checklist for PRs

- Does this change alter request context parsing?
- Does it change fail-open/fail-closed behavior?
- Does it add dynamic I/O in hot path?
- Does it affect kill-switch ordering or shadow semantics?
- Are new headers/claims validated and normalized consistently?
