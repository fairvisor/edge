# Release Process

## Versioning

Use Semantic Versioning tags: `vMAJOR.MINOR.PATCH`.

## Release Artifacts

Publish container artifacts for every release:

- Runtime image: `ghcr.io/fairvisor/fairvisor-edge:<tag>`
- CLI image: `ghcr.io/fairvisor/fairvisor-cli:<tag>`
- Runtime immutable tag: `ghcr.io/fairvisor/fairvisor-edge:sha-<git-sha>`
- CLI immutable tag: `ghcr.io/fairvisor/fairvisor-cli:sha-<git-sha>`

Do not ship `deb/rpm` packages in the current release track.

## Release Checklist

1. Move release notes from `[Unreleased]` into a new heading:
   - `## [X.Y.Z]` or `## [vX.Y.Z]`
2. Confirm tests pass locally:
   - `busted spec`
   - `pytest tests/e2e -v`
3. Verify docs and examples for behavior changes.
4. Build and verify container images:
   - runtime (`docker/Dockerfile`)
   - CLI (`docker/Dockerfile.cli`)
5. Verify vulnerability policy:
   - fail release on `HIGH` / `CRITICAL`
   - review `MEDIUM` findings
6. Sign images and publish provenance attestations.
7. Tag release: `git tag vX.Y.Z`.
8. Push tag and publish release notes.

## Build-Time Data Generation

Runtime image build generates runtime maps directly from upstream sources:

- ASN mapping: `bin/generate_asn_type_map.py`
- Tor exits geo map: `bin/generate_tor_exit_geo.py`

Build fails if generated files are empty.

## Release Notes Template

- Summary of key behavior changes
- Breaking changes and migration guidance
- Security fixes
- Known limitations
- Artifact tags and digests for runtime and CLI images
- Signature and provenance references

## Rollback Guidance

- Revert to previous stable tag.
- Re-deploy previous known-good policy bundle.
- Pin deployments to the previous image tag.
- Publish incident note with impact and mitigation.
