# Feature: ASN type mapping in nginx map include
# Rule: X-ASN is mapped via /etc/fairvisor/asn_type.map and exposed as ip:type descriptor.

import uuid

import requests


class TestAsnTypeMapE2E:
    """E2E: ip:type descriptor is derived from nginx ASN map and enforced in rules."""

    def test_known_asn_type_is_enforced_with_shared_bucket(self, edge_asn_base_url):
        """Scenario: Known ASN (72 -> business) should map to one ip:type bucket and reject on second hit."""
        headers = {
            "X-Original-Method": "GET",
            "X-Original-URI": f"/asn/{uuid.uuid4().hex[:8]}",
            "X-ASN": "72",
            "X-E2E-Key": f"asn-enterprise-{uuid.uuid4().hex[:8]}",
        }

        first = requests.post(f"{edge_asn_base_url}/v1/decision", headers=headers, timeout=5)
        second = requests.post(f"{edge_asn_base_url}/v1/decision", headers=headers, timeout=5)

        assert first.status_code == 200
        assert second.status_code == 429
        assert "X-Fairvisor-Reason" not in second.headers

    def test_unknown_asn_uses_default_unknown_type(self, edge_asn_base_url):
        """Scenario: Unmapped ASN should resolve to unknown and enforce bucket against that type."""
        headers = {
            "X-Original-Method": "GET",
            "X-Original-URI": f"/asn/{uuid.uuid4().hex[:8]}",
            "X-ASN": "999999999",
            "X-E2E-Key": f"asn-unknown-{uuid.uuid4().hex[:8]}",
        }

        first = requests.post(f"{edge_asn_base_url}/v1/decision", headers=headers, timeout=5)
        second = requests.post(f"{edge_asn_base_url}/v1/decision", headers=headers, timeout=5)

        assert first.status_code == 200
        assert second.status_code == 429

    def test_different_asn_types_use_independent_buckets(self, edge_asn_base_url):
        """Scenario: Different mapped types (business vs hosting) should not consume each other's bucket."""
        business_headers = {
            "X-Original-Method": "GET",
            "X-Original-URI": f"/asn/{uuid.uuid4().hex[:8]}",
            "X-ASN": "72",
            "X-E2E-Key": f"asn-shared-{uuid.uuid4().hex[:8]}",
        }
        hosting_headers = {
            "X-Original-Method": "GET",
            "X-Original-URI": f"/asn/{uuid.uuid4().hex[:8]}",
            "X-ASN": "62",
            "X-E2E-Key": business_headers["X-E2E-Key"],
        }

        business_first = requests.post(
            f"{edge_asn_base_url}/v1/decision", headers=business_headers, timeout=5
        )
        hosting_first = requests.post(
            f"{edge_asn_base_url}/v1/decision", headers=hosting_headers, timeout=5
        )

        assert business_first.status_code == 200
        assert hosting_first.status_code == 200
