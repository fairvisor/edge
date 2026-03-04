# Security Policy

## Reporting a Vulnerability

Please do not disclose vulnerabilities in public issues.

Use one of these private channels:

- GitHub private vulnerability reporting (preferred)
- Direct maintainer contact listed in `MAINTAINERS.md`

## Triage and Response Targets

- Initial triage response: within 72 hours
- Status update cadence: at least every 7 days while open
- Fix timeline: depends on severity and exploitability

## Disclosure Policy

We follow coordinated disclosure:

1. Reporter submits private report.
2. Maintainers reproduce and assess impact.
3. Fix is prepared and validated.
4. Advisory is published with mitigation guidance.

## Scope Notes

Security reports are especially relevant for:

- policy bypass or unintended fail-open behavior
- authentication/authorization descriptor handling issues
- header/query parsing ambiguity leading to enforcement gaps
- resource exhaustion in hot-path enforcement logic

