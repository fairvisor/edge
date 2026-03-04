# CI/CD

Fairvisor Edge uses GitHub Actions for CI/CD.

## Workflows

- `ci.yml` (push to `main`, pull requests):
  - policy JSON validation (syntax + Fairvisor semantic validation)
  - nginx template render/syntax check
  - Lua quality checks (`luacheck`, `busted spec/unit/`, `busted spec/integration/`)
  - smoke E2E
  - runtime/CLI vulnerability scan and SBOM generation
- `nightly-e2e.yml`:
  - full Docker Compose E2E suite (`pytest tests/e2e -v`)
  - uploads compose logs and junit report
- `security-nightly.yml`:
  - nightly high/critical scan of runtime and CLI images
- `release.yml` (tags `vMAJOR.MINOR.PATCH`):
  - preflight checks (tag/changelog, Lua quality, full E2E)
  - build and push runtime + CLI images to GHCR
  - scan pushed images (`HIGH`, `CRITICAL` gate)
  - sign images with keyless cosign (OIDC)
  - publish provenance attestations
  - create GitHub Release

## PR Merge Gates

`main` branch protection should require:

- `validate-config-and-policies`
- `lua-quality`
- `e2e-smoke`
- `security-scan-pr`

## Security Policy

- PR/release pipelines fail on `HIGH` or `CRITICAL` vulnerabilities.
- `MEDIUM` findings are reported for triage but do not block.
- SBOM artifacts are generated for both runtime and CLI images.

## Release Notes Inputs

Release jobs consume:

- Git tag (`vX.Y.Z`)
- matching section in `CHANGELOG.md`
- image digest outputs from build jobs

## Local Reproduction

Run the same core checks locally:

```bash
docker build -f docker/Dockerfile.test -t fairvisor-test-ci .
docker run --rm -v "$PWD:/work" -w /work fairvisor-test-ci bin/ci/run_lua_tests.sh
pip install -r tests/e2e/requirements.txt
bin/ci/run_e2e_smoke.sh
```
