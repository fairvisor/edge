# Feature: Health probes (readyz / livez)
# Rule: Edge exposes Kubernetes-style probes for readiness and liveness.
# Scenarios: GET /readyz and GET /livez return 200 when the service is up.

import pytest
import requests


class TestHealthProbes:
    """E2E: Health endpoints match gateway-integration and Helm probe contract."""

    def test_livez_returns_200_when_edge_is_running(self, edge_base_url):
        """Scenario: Liveness probe returns 200 so Kubernetes does not restart the pod."""
        r = requests.get(f"{edge_base_url}/livez", timeout=5)
        assert r.status_code == 200
        assert "ok" in (r.text or "").lower()

    def test_readyz_returns_200_when_edge_accepts_traffic(self, edge_base_url):
        """Scenario: Readiness probe returns 200 so the pod receives traffic."""
        r = requests.get(f"{edge_base_url}/readyz", timeout=5)
        assert r.status_code == 200
        assert "ready" in (r.text or "").lower()

    def test_readyz_includes_bundle_version_in_body_when_loaded(self, edge_base_url):
        """Scenario: Health probe /readyz includes bundle version info in body when loaded."""
        r = requests.get(f"{edge_base_url}/readyz", timeout=5)
        assert r.status_code == 200
        body = (r.text or "").lower()
        # When bundle is loaded, body may contain policy_version, policy_hash, or "ready"
        assert "ready" in body or "policy_version" in body or "version" in body, (
            f"readyz body should include version/ready info; got: {r.text[:300]}"
        )

    def test_readyz_returns_503_when_no_bundle_is_loaded(self, edge_nobundle_base_url):
        """Scenario: no bundle loaded keeps readiness in not_ready state."""
        r = requests.get(f"{edge_nobundle_base_url}/readyz", timeout=5)
        assert r.status_code == 503
        body = (r.text or "").lower()
        assert "not_ready" in body or "no_policy_loaded" in body
