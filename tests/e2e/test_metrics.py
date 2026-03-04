# Feature: Metrics and debug headers (E2E)

import requests


class TestMetricsEndpoint:
    REQUIRED_METRICS = (
        "fairvisor_decisions_total",
        "fairvisor_decision_duration_seconds",
        "fairvisor_ratelimit_remaining",
        "fairvisor_tokens_consumed_total",
        "fairvisor_tokens_remaining",
        "fairvisor_token_estimation_accuracy_ratio",
        "fairvisor_token_reservation_unused_total",
        "fairvisor_loop_detected_total",
        "fairvisor_circuit_state",
        "fairvisor_kill_switch_active",
        "fairvisor_shadow_mode_active",
        "fairvisor_global_shadow_active",
        "fairvisor_kill_switch_override_active",
        "fairvisor_saas_reachable",
        "fairvisor_saas_calls_total",
        "fairvisor_events_sent_total",
        "fairvisor_config_info",
        "fairvisor_build_info",
    )

    def test_metrics_endpoint_returns_prometheus_text(self, edge_base_url):
        r = requests.get(f"{edge_base_url}/metrics", timeout=5)
        assert r.status_code == 200
        body = r.text or ""
        assert "# HELP" in body
        assert "# TYPE" in body

    def test_decision_requests_are_exported_in_metrics(self, edge_base_url):
        headers = {
            "X-Original-Method": "GET",
            "X-Original-URI": "/api/v1/metrics-check",
        }
        for _ in range(3):
            requests.post(f"{edge_base_url}/v1/decision", headers=headers, timeout=5)

        r = requests.get(f"{edge_base_url}/metrics", timeout=5)
        assert r.status_code == 200
        body = r.text or ""
        for metric_name in self.REQUIRED_METRICS:
            assert metric_name in body


class TestDebugHeaders:
    def test_debug_headers_are_absent_by_default(self, edge_base_url):
        r = requests.post(
            f"{edge_base_url}/v1/decision",
            headers={
                "X-Original-Method": "GET",
                "X-Original-URI": "/api/v1/no-debug-headers",
            },
            timeout=5,
        )
        assert r.status_code == 200
        assert r.headers.get("X-Fairvisor-Decision") is None
        assert r.headers.get("X-Fairvisor-Mode") is None
        assert r.headers.get("X-Fairvisor-Latency-Us") is None
