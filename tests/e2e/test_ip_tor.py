# Feature: Tor exit selector from nginx geo map
# Rule: ip:tor descriptor is enforced as boolean selector and participates in bucket keys.

import uuid

import requests


class TestIpTorSelectorE2E:
    """E2E: ip:tor descriptor comes from nginx variable mapping (or explicit header fallback)."""

    def test_tor_exit_traffic_is_limited_on_repeated_requests(self, edge_asn_base_url):
        """Scenario: tor=true requests hit ip:tor rule and get rejected after burst is exhausted."""
        key = f"tor-{uuid.uuid4().hex[:8]}"
        tor_headers = {
            "X-Original-Method": "POST",
            "X-Original-URI": f"/tor/{uuid.uuid4().hex[:8]}",
            "X-Tor-Exit": "1",
            "X-E2E-Key": key,
        }

        first_tor = requests.post(f"{edge_asn_base_url}/v1/decision", headers=tor_headers, timeout=5)
        second_tor = requests.post(f"{edge_asn_base_url}/v1/decision", headers=tor_headers, timeout=5)

        assert first_tor.status_code == 200
        assert second_tor.status_code == 429
        assert "X-Fairvisor-Reason" not in second_tor.headers
