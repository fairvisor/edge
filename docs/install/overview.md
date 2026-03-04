# Installation Overview

Fairvisor is distributed as container images and installed as infrastructure runtime.

## Official Install Profiles

- Kubernetes via Helm (`helm/fairvisor-edge`)
- VM/metal via `docker run` and `systemd`
- Local smoke testing via Docker Compose
- Troubleshooting guide (`docs/install/troubleshooting.md`)

## Artifacts

- Runtime image: `ghcr.io/fairvisor/fairvisor-edge:<version>`
- CLI image: `ghcr.io/fairvisor/fairvisor-cli:<version>`

## Configuration Modes

- SaaS mode: set `FAIRVISOR_SAAS_URL`, `FAIRVISOR_EDGE_ID`, `FAIRVISOR_EDGE_TOKEN`
- Standalone mode: mount a local policy bundle and set `FAIRVISOR_CONFIG_FILE`

Both modes are supported in production.
