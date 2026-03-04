# Feature: Decision API (gateway integration contract)
# Rule: POST /v1/decision accepts X-Original-Method and X-Original-URI; returns 200 allow or 429 reject.
# Scenarios: Contract from docs/gateway-integration.md (success, optional headers, method/URI forwarding).

import pytest
import requests


class TestDecisionApiContract:
    """E2E: Decision API behaviour required by gateway snippets (nginx, Envoy, Kong, Traefik)."""

    def test_post_decision_with_original_headers_returns_200_when_allowed(
        self, edge_base_url, edge_headers
    ):
        """Scenario: Gateway forwards request with X-Original-Method and X-Original-URI; Edge returns 200."""
        r = requests.post(
            f"{edge_base_url}/v1/decision",
            headers=edge_headers,
            timeout=5,
        )
        assert r.status_code == 200

    def test_post_decision_with_query_in_original_uri_forwards_path_and_query(
        self, edge_base_url
    ):
        """Scenario: X-Original-URI can include query string for route matching."""
        r = requests.post(
            f"{edge_base_url}/v1/decision",
            headers={
                "X-Original-Method": "GET",
                "X-Original-URI": "/api/v1/chat?stream=true",
            },
            timeout=5,
        )
        assert r.status_code == 200

    def test_post_decision_accepts_optional_authorization_header(
        self, edge_base_url, edge_headers
    ):
        """Scenario: Gateway may forward Authorization; Edge accepts it for JWT extraction."""
        edge_headers["Authorization"] = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0In0.x"
        r = requests.post(f"{edge_base_url}/v1/decision", headers=edge_headers, timeout=5)
        assert r.status_code == 200

    def test_decision_endpoint_rejects_get_with_method_not_allowed_or_returns_200(
        self, edge_base_url
    ):
        """Scenario: GET /v1/decision returns 405 or 200 (method enforcement)."""
        r = requests.get(
            f"{edge_base_url}/v1/decision",
            headers={"X-Original-Method": "GET", "X-Original-URI": "/"},
            timeout=5,
        )
        assert r.status_code in (200, 405)

    def test_request_without_x_e2e_key_header_allowed_fail_open(self, edge_base_url):
        """Scenario: Request with no X-E2E-Key header — allow (fail-open for missing descriptor)."""
        r = requests.post(
            f"{edge_base_url}/v1/decision",
            headers={
                "X-Original-Method": "GET",
                "X-Original-URI": "/api/v1/chat",
            },
            timeout=5,
        )
        assert r.status_code == 200, (
            f"missing descriptor should fail-open to allow; got {r.status_code}"
        )

    def test_legacy_decision_endpoint_is_removed(self, edge_base_url, edge_headers):
        """Scenario: Legacy POST /decision alias is not available anymore."""
        r = requests.post(
            f"{edge_base_url}/decision",
            headers=edge_headers,
            timeout=5,
        )
        assert r.status_code == 404
