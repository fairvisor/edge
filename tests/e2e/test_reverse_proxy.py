import uuid

import requests


class TestReverseProxyMode:
    """E2E: reverse_proxy mode enforces policy and then proxies to backend."""

    def test_reverse_proxy_forwards_allowed_requests_to_backend(self, edge_reverse_base_url):
        response = requests.get(
            f"{edge_reverse_base_url}/",
            headers={"X-E2E-Key": f"rp-allow-{uuid.uuid4().hex[:8]}"},
            timeout=5,
        )
        assert response.status_code == 200
        assert "nginx" in (response.text or "").lower()

    def test_reverse_proxy_enforces_rate_limit_before_proxy(self, edge_reverse_base_url):
        key = f"rp-limit-{uuid.uuid4().hex[:8]}"
        headers = {"X-E2E-Key": key}

        first = requests.get(f"{edge_reverse_base_url}/", headers=headers, timeout=5)
        second = requests.get(f"{edge_reverse_base_url}/", headers=headers, timeout=5)
        third = requests.get(f"{edge_reverse_base_url}/", headers=headers, timeout=5)

        assert first.status_code == 200
        assert second.status_code in (200, 429)
        assert third.status_code == 429, (
            f"expected reverse_proxy limiter reject on repeated requests, got "
            f"{(first.status_code, second.status_code, third.status_code)}"
        )
        assert "X-Fairvisor-Reason" not in third.headers
        assert third.headers.get("Retry-After") is not None
