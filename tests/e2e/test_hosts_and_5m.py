# Feature: Hosts selector and 5m budget window (E2E)
# Rule: Host-aware routing and 5-minute budget behavior are enforced in real nginx runtime.

import uuid

import requests


class TestHostsSelectorE2E:
    """E2E: selector.hosts scopes enforcement by X-Original-Host."""

    def test_host_scoped_policy_rejects_for_matching_host(self, edge_hosts_base_url):
        """Scenario: Requests for api.example.com are enforced by host-scoped limiter."""
        key = f"host-api-{uuid.uuid4().hex[:8]}"
        headers = {
            "X-Original-Method": "GET",
            "X-Original-URI": "/v1/chat",
            "X-Original-Host": "api.example.com",
            "X-E2E-Key": key,
        }

        first = requests.post(f"{edge_hosts_base_url}/v1/decision", headers=headers, timeout=5)
        second = requests.post(f"{edge_hosts_base_url}/v1/decision", headers=headers, timeout=5)
        third = requests.post(f"{edge_hosts_base_url}/v1/decision", headers=headers, timeout=5)

        assert first.status_code == 200
        assert second.status_code in (200, 429)
        assert third.status_code == 429, (
            f"expected host-scoped limiter to reject for api.example.com; "
            f"statuses={(first.status_code, second.status_code, third.status_code)}"
        )

    def test_host_scoped_policy_not_applied_for_other_host(self, edge_hosts_base_url):
        """Scenario: Requests for non-matching host bypass host-scoped limiter and stay allowed."""
        key = f"host-admin-{uuid.uuid4().hex[:8]}"
        headers = {
            "X-Original-Method": "GET",
            "X-Original-URI": "/v1/chat",
            "X-Original-Host": "admin.example.com",
            "X-E2E-Key": key,
        }

        statuses = []
        for _ in range(4):
            response = requests.post(f"{edge_hosts_base_url}/v1/decision", headers=headers, timeout=5)
            statuses.append(response.status_code)

        assert statuses == [200, 200, 200, 200], (
            f"expected non-matching host to remain allow-only; got {statuses}"
        )


class TestBudget5mE2E:
    """E2E: cost_based period=5m is accepted and enforced."""

    def test_period_5m_budget_rejects_after_budget_is_consumed(self, edge_5m_base_url):
        """Scenario: Second request in same 5m window rejects when budget=1 and fixed_cost=1."""
        key = f"budget-5m-{uuid.uuid4().hex[:8]}"
        headers = {
            "X-Original-Method": "GET",
            "X-Original-URI": "/v1/chat",
            "X-E2E-Key": key,
        }

        first = requests.post(f"{edge_5m_base_url}/v1/decision", headers=headers, timeout=5)
        second = requests.post(f"{edge_5m_base_url}/v1/decision", headers=headers, timeout=5)

        assert first.status_code == 200
        assert first.headers.get("X-Fairvisor-Warning") in {"budget_warn", "budget_throttle"}
        assert second.status_code == 429, (
            f"expected second request to exceed 5m budget; got {second.status_code}"
        )
        assert "X-Fairvisor-Reason" not in second.headers
        assert "Retry-After" in second.headers

        retry_after = int(second.headers["Retry-After"])
        assert 1 <= retry_after <= 300, (
            f"5m period should produce retry_after <= 300; got {retry_after}"
        )
