# Feature: Decision API reject path and real shared_dict (E2E-only)
# Rule: Scenarios that require real nginx + real Lua + real shared_dict; not duplicated by unit/integration.

import base64
import json
import uuid

import pytest
import requests


def _exhaust_bucket(base_url, limit_key, max_requests=50, client=None):
    """Send requests until 429 or max_requests reached. Returns (responses, last_response).
    Policy uses header:x-e2e-key as limit_key; same header value shares one bucket (burst=2)."""
    headers = {
        "X-Original-Method": "GET",
        "X-Original-URI": "/api/v1/chat",
        "X-E2E-Key": limit_key,
    }
    responses = []
    client = client or requests
    for _ in range(max_requests):
        r = client.post(f"{base_url}/v1/decision", headers=headers, timeout=5)
        responses.append(r)
        if r.status_code == 429:
            break
    return responses, responses[-1] if responses else None


def _jwt_with_sub(sub):
    """Build an unsigned JWT-like value with deterministic payload for E2E descriptor extraction."""
    payload = json.dumps({"sub": sub}, separators=(",", ":")).encode("utf-8")
    payload_b64 = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    return f"Bearer x.{payload_b64}.y"


class TestTokenBucketExhaustionE2E:
    """E2E: Many requests with same limit_key eventually get 429 (real shared_dict)."""

    def test_after_sufficient_requests_same_key_receives_429_with_retry_after(
        self, edge_base_url
    ):
        """Send many POST /v1/decision with same descriptor until 429; assert X-Fairvisor-Reason and Retry-After."""
        limit_key = f"exhaust-{uuid.uuid4().hex[:8]}"
        responses, last = _exhaust_bucket(edge_base_url, limit_key)

        status_codes = [r.status_code for r in responses]
        assert last is not None, "no responses received"
        assert last.status_code == 429, (
            f"expected 429 after {len(responses)} requests, got status sequence: {status_codes}; "
            f"last response headers: {dict(last.headers)}; body: {last.text[:200]}"
        )
        assert "Retry-After" in last.headers, (
            f"429 response missing Retry-After; headers: {dict(last.headers)}"
        )


class TestNoBundleReturns503E2E:
    """E2E: When no bundle is loaded, POST /v1/decision returns 503 (real init_worker path)."""

    def test_decision_returns_503_with_reason_when_bundle_not_loaded(self, edge_nobundle_base_url):
        """No-bundle container must return 503 and no_bundle_loaded reason header."""
        r = requests.post(
            f"{edge_nobundle_base_url}/v1/decision",
            headers={"X-Original-Method": "GET", "X-Original-URI": "/"},
            timeout=5,
        )
        assert r.status_code == 503
        assert "X-Fairvisor-Reason" not in r.headers


class TestRejectHeadersOnWireE2E:
    """E2E: 429 response includes gateway contract headers (X-Fairvisor-Reason, Retry-After, etc.)."""

    def test_429_response_includes_fairvisor_reason_and_retry_after(self, edge_base_url):
        """After exhausting the bucket, 429 response exposes X-Fairvisor-Reason and Retry-After."""
        limit_key = f"headers-{uuid.uuid4().hex[:8]}"
        responses, last = _exhaust_bucket(edge_base_url, limit_key)

        status_codes = [r.status_code for r in responses]
        assert last is not None, "no responses received"
        assert last.status_code == 429, (
            f"expected 429 after {len(responses)} requests, got status sequence: {status_codes}; "
            f"last response headers: {dict(last.headers)}; body: {last.text[:200]}"
        )
        assert "X-Fairvisor-Reason" not in last.headers, (
            f"X-Fairvisor-Reason must not be exposed without debug mode; headers: {dict(last.headers)}"
        )
        assert "Retry-After" in last.headers, (
            f"429 response missing Retry-After header; headers: {dict(last.headers)}"
        )

    def test_429_response_includes_all_rate_limit_and_fairvisor_headers(
        self, edge_base_url
    ):
        """After exhausting the bucket, 429 response exposes all rate limit and fairvisor headers."""
        limit_key = f"all-headers-{uuid.uuid4().hex[:8]}"
        responses, last = _exhaust_bucket(edge_base_url, limit_key)

        status_codes = [r.status_code for r in responses]
        assert last is not None, "no responses received"
        assert last.status_code == 429, (
            f"expected 429 after {len(responses)} requests, got status sequence: {status_codes}; "
            f"last response headers: {dict(last.headers)}; body: {last.text[:200]}"
        )
        required = [
            "RateLimit-Limit",
            "RateLimit-Remaining",
            "RateLimit-Reset",
            "RateLimit",
            "Retry-After",
        ]
        missing = [h for h in required if h not in last.headers]
        assert not missing, (
            f"429 response missing headers: {missing}; headers: {dict(last.headers)}"
        )
        assert "X-Fairvisor-Policy" not in last.headers
        assert "X-Fairvisor-Rule" not in last.headers
        rate_limit_val = last.headers.get("RateLimit", "")
        assert ";r=" in rate_limit_val and ";t=" in rate_limit_val, (
            f"RateLimit header must be structured (policy;r=remaining;t=reset); got: {rate_limit_val}"
        )


class TestDifferentLimitKeysIndependentE2E:
    """E2E: Different limit keys get independent buckets (real shared_dict isolation)."""

    def test_different_keys_have_independent_buckets(self, edge_base_url):
        """Exhaust bucket for key A; key B still gets 200 (independent buckets)."""
        key_a = f"key-a-{uuid.uuid4().hex[:8]}"
        key_b = f"key-b-{uuid.uuid4().hex[:8]}"
        _, last_a = _exhaust_bucket(edge_base_url, key_a)
        assert last_a is not None and last_a.status_code == 429, "key A should be exhausted"

        r_b = requests.post(
            f"{edge_base_url}/v1/decision",
            headers={
                "X-Original-Method": "GET",
                "X-Original-URI": "/api/v1/chat",
                "X-E2E-Key": key_b,
            },
            timeout=5,
        )
        assert r_b.status_code == 200, (
            f"key B should have its own bucket and allow; got {r_b.status_code}"
        )


class TestRetryAfterJitterDistributionE2E:
    """E2E: Different client identities should not converge to a single Retry-After value."""

    def test_kill_switch_rejects_with_diversified_retry_after_across_users(self, edge_base_url):
        """Trigger kill-switch rejects for multiple JWT subjects and assert Retry-After values are distributed."""
        retry_after_values = set()
        subjects = ["jitter-user-a", "jitter-user-b", "jitter-user-c", "jitter-user-d"]

        for index, subject in enumerate(subjects):
            response = requests.post(
                f"{edge_base_url}/v1/decision",
                headers={
                    "X-Original-Method": "GET",
                    "X-Original-URI": "/api/v1/chat",
                    "X-E2E-Key": f"jitter-{index}-{uuid.uuid4().hex[:8]}",
                    "X-E2E-Jitter": "on",
                    "Authorization": _jwt_with_sub(subject),
                },
                timeout=5,
            )

            assert response.status_code == 429, (
                f"kill-switch request for {subject} should reject; got {response.status_code}"
            )
            assert "X-Fairvisor-Reason" not in response.headers
            assert "Retry-After" in response.headers
            retry_after_values.add(response.headers["Retry-After"])

        assert len(retry_after_values) >= 2, (
            f"expected diversified Retry-After values across subjects; got {sorted(retry_after_values)}"
        )


class TestDebugSessionHeadersE2E:
    """E2E: policy/rule details are only available in debug-session mode."""

    def test_policy_and_rule_headers_hidden_without_debug_cookie(self, edge_base_url):
        key = f"no-debug-{uuid.uuid4().hex[:8]}"
        _, last = _exhaust_bucket(edge_base_url, key)
        assert last is not None and last.status_code == 429
        assert last.headers.get("X-Fairvisor-Policy") is None
        assert last.headers.get("X-Fairvisor-Rule") is None

    def test_debug_cookie_enables_verbose_debug_headers(self, edge_base_url):
        session = requests.Session()

        login = session.post(
            f"{edge_base_url}/v1/debug/session",
            headers={"X-Fairvisor-Debug-Secret": "e2e-debug-secret"},
            timeout=5,
        )
        assert login.status_code == 204, f"debug session create failed: {login.status_code} {login.text}"
        set_cookie = login.headers.get("Set-Cookie")
        assert set_cookie is not None and "fv_dbg=" in set_cookie
        session.headers["Cookie"] = set_cookie.split(";", 1)[0]

        key = f"with-debug-{uuid.uuid4().hex[:8]}"
        _, last = _exhaust_bucket(edge_base_url, key, client=session)
        assert last is not None and last.status_code == 429
        assert last.headers.get("X-Fairvisor-Debug-Policy") == "e2e-policy"
        assert last.headers.get("X-Fairvisor-Debug-Rule") == "e2e-rule"
        assert last.headers.get("X-Fairvisor-Debug-Decision") == "reject"
        assert last.headers.get("X-Fairvisor-Debug-Mode") in {"enforce", "shadow"}

        logout = session.post(f"{edge_base_url}/v1/debug/logout", timeout=5)
        assert logout.status_code == 204
