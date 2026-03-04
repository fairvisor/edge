# Compatibility Policy

## SemVer Contract

- MAJOR: breaking behavior or interface changes
- MINOR: backward-compatible functionality additions
- PATCH: backward-compatible bug fixes

## What Is Breaking

Examples:

- Changing decision semantics for existing valid policy bundles
- Removing supported config fields without deprecation
- Renaming mandatory headers or CLI flags without compatibility shims

## Deprecation Policy

- Mark deprecated behavior in docs and changelog.
- Keep deprecated behavior for at least one MINOR release when practical.
- Provide explicit migration instructions before removal.

## Runtime Compatibility Expectations

- Policy bundles valid for a released version should remain valid across PATCH releases.
- Any exception must be clearly documented in release notes.
