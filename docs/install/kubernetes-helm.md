# Kubernetes Installation (Helm)

## Prerequisites

- Kubernetes cluster
- Helm 3+
- Access to Fairvisor image registry

## Install

```bash
helm upgrade --install fairvisor-edge ./helm/fairvisor-edge \
  --set image.repository=ghcr.io/fairvisor/fairvisor-edge \
  --set image.tag=v0.1.0 \
  --set mode=decision_service \
  --set standalone.policy.existingConfigMapRef=fairvisor-policy
```

## SaaS Mode Example

```bash
helm upgrade --install fairvisor-edge ./helm/fairvisor-edge \
  --set image.repository=ghcr.io/fairvisor/fairvisor-edge \
  --set image.tag=v0.1.0 \
  --set saas.url=https://api.fairvisor.com \
  --set saas.edgeId=edge-prod-1 \
  --set saas.edgeTokenSecretRef=fairvisor-edge-secret
```

## Reverse Proxy Example

```bash
helm upgrade --install fairvisor-edge ./helm/fairvisor-edge \
  --set image.repository=ghcr.io/fairvisor/fairvisor-edge \
  --set image.tag=v0.1.0 \
  --set mode=reverse_proxy \
  --set backendUrl=http://backend.default.svc.cluster.local:8080 \
  --set standalone.policy.existingConfigMapRef=fairvisor-policy
```

## Required Value Rules

- `mode` must be `decision_service` or `reverse_proxy`
- `backendUrl` is required when `mode=reverse_proxy`
- Set exactly one source type:
  - SaaS mode (`saas.url` + credentials)
  - Standalone policy source (`standalone.policy.inlineJson` or existing ConfigMap/Secret)
- For SaaS mode, set exactly one token source:
  - `saas.edgeToken`
  - `saas.edgeTokenSecretRef`

## Health Checks

- Liveness: `/livez`
- Readiness: `/readyz`
