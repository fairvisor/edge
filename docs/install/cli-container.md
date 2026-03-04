# CLI Installation (Containerized)

Fairvisor CLI is available as a container image.

## Pull

```bash
docker pull ghcr.io/fairvisor/fairvisor-cli:v0.1.0
```

## Run commands

```bash
docker run --rm -v "$PWD:/work" -w /work ghcr.io/fairvisor/fairvisor-cli:v0.1.0 help
docker run --rm -v "$PWD:/work" -w /work ghcr.io/fairvisor/fairvisor-cli:v0.1.0 validate policy.json
docker run --rm -v "$PWD:/work" -w /work ghcr.io/fairvisor/fairvisor-cli:v0.1.0 test policy.json
```

## Notes

- Containerized CLI is the official operator/CI path.
- `./bin/fairvisor` remains valid for source-based local development.
