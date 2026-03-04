# Feature: Operational / logging (E2E)
# Rule: Scenarios that validate operational behaviour (logs, env).
# E5: Container with FAIRVISOR_LOG_LEVEL=debug — debug output appears in logs.
#     Run: docker compose -f tests/e2e/docker-compose.test.yml --profile debug up -d

import pytest
import requests

from conftest import _fetch_container_logs


class TestDebugLogLevelE2E:
    """E2E: Debug log level produces debug output (requires --profile debug)."""

    def test_debug_log_level_produces_debug_output_in_logs(self, edge_debug_base_url):
        """Scenario: Container with FAIRVISOR_LOG_LEVEL=debug — debug output appears in logs."""
        requests.post(
            f"{edge_debug_base_url}/v1/decision",
            headers={
                "X-Original-Method": "GET",
                "X-Original-URI": "/api/v1/chat",
                "X-E2E-Key": "debug-check",
            },
            timeout=5,
        )
        logs = _fetch_container_logs(tail=100, service="edge_debug")
        assert "debug" in logs.lower(), (
            "Expected [debug] or 'debug' in edge_debug logs when FAIRVISOR_LOG_LEVEL=debug. "
            "Logs (last 100 lines): %s" % (logs[-2000:] if len(logs) > 2000 else logs)
        )
