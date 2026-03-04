# E2E tests: Fairvisor Edge in Docker (standalone mode).
# Prerequisite: from repo root run:
#   docker compose -f tests/e2e/docker-compose.test.yml up -d --build
# Then: pytest tests/e2e -v

import os
import subprocess
import time

import pytest
import requests


EDGE_BASE_URL = os.environ.get("FAIRVISOR_E2E_URL", "http://localhost:18080")
EDGE_DEBUG_URL = os.environ.get("FAIRVISOR_E2E_DEBUG_URL", "http://localhost:18081")
EDGE_HOSTS_URL = os.environ.get("FAIRVISOR_E2E_HOSTS_URL", "http://localhost:18082")
EDGE_5M_URL = os.environ.get("FAIRVISOR_E2E_5M_URL", "http://localhost:18083")
EDGE_NOBUNDLE_URL = os.environ.get("FAIRVISOR_E2E_NOBUNDLE_URL", "http://localhost:18084")
EDGE_REVERSE_URL = os.environ.get("FAIRVISOR_E2E_REVERSE_URL", "http://localhost:18085")
EDGE_ASN_URL = os.environ.get("FAIRVISOR_E2E_ASN_URL", "http://localhost:18087")
HEALTH_TIMEOUT_S = float(os.environ.get("FAIRVISOR_E2E_HEALTH_TIMEOUT", "15"))
COMPOSE_FILE = os.path.join(os.path.dirname(__file__), "docker-compose.test.yml")


def _fetch_container_logs(tail=80, service=None):
    """Fetch recent container logs for diagnostics on failure.
    If service is set (e.g. 'edge_debug'), only that service's logs are returned."""
    try:
        cmd = ["docker", "compose", "-f", COMPOSE_FILE, "logs", "--tail", str(tail), "--no-color"]
        if service:
            cmd.append(service)
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return result.stdout or result.stderr or "(no output)"
    except Exception as e:
        return f"(failed to fetch logs: {e})"


def _wait_ready(url, timeout_s):
    deadline = time.monotonic() + timeout_s
    last_error = None
    while time.monotonic() < deadline:
        try:
            r = requests.get(f"{url}/readyz", timeout=2)
            if r.status_code == 200:
                return True, None
            last_error = f"readyz returned {r.status_code}"
        except requests.RequestException as e:
            last_error = str(e)
        time.sleep(0.5)
    return False, last_error


def _wait_livez(url, timeout_s):
    deadline = time.monotonic() + timeout_s
    last_error = None
    while time.monotonic() < deadline:
        try:
            r = requests.get(f"{url}/livez", timeout=2)
            if r.status_code == 200:
                return True, None
            last_error = f"livez returned {r.status_code}"
        except requests.RequestException as e:
            last_error = str(e)
        time.sleep(0.5)
    return False, last_error


@pytest.fixture(scope="session")
def edge_base_url():
    """Base URL of the Edge container. Waits for /readyz before first use."""
    url = EDGE_BASE_URL
    ready, last_error = _wait_ready(url, HEALTH_TIMEOUT_S)
    if ready:
        return url
    logs = _fetch_container_logs(tail=40)
    pytest.skip(
        f"Edge not ready at {url} within {HEALTH_TIMEOUT_S}s. "
        f"Last error: {last_error}\n"
        f"Container logs:\n{logs}\n"
        "Run: docker compose -f tests/e2e/docker-compose.test.yml up -d --build"
    )


@pytest.fixture
def edge_headers():
    """Minimal headers for Decision API (gateway integration contract)."""
    return {
        "X-Original-Method": "GET",
        "X-Original-URI": "/api/v1/example",
    }


@pytest.fixture
def fetch_edge_logs():
    """Fixture that returns a callable to fetch container logs for debugging."""
    return _fetch_container_logs


@pytest.fixture(scope="session")
def edge_debug_base_url():
    """Base URL of the Edge container with FAIRVISOR_LOG_LEVEL=debug (profile debug).
    Skips if edge_debug is not up (e.g. started without --profile debug)."""
    url = EDGE_DEBUG_URL
    ready, _ = _wait_ready(url, 5)
    if ready:
        return url
    pytest.skip(
        "Edge debug container not ready at {}. Run: docker compose -f tests/e2e/docker-compose.test.yml up -d".format(url)
    )


@pytest.fixture(scope="session")
def edge_hosts_base_url():
    """Base URL of the hosts-selector profile container."""
    url = EDGE_HOSTS_URL
    ready, _ = _wait_ready(url, 5)
    if ready:
        return url
    pytest.skip(
        "Edge hosts container not ready at {}. Run: docker compose -f tests/e2e/docker-compose.test.yml up -d".format(url)
    )


@pytest.fixture(scope="session")
def edge_5m_base_url():
    """Base URL of the 5m-budget profile container."""
    url = EDGE_5M_URL
    ready, _ = _wait_ready(url, 5)
    if ready:
        return url
    pytest.skip(
        "Edge 5m container not ready at {}. Run: docker compose -f tests/e2e/docker-compose.test.yml up -d".format(url)
    )


@pytest.fixture(scope="session")
def edge_nobundle_base_url():
    """Base URL of the no-bundle profile container (live but not ready)."""
    url = EDGE_NOBUNDLE_URL
    alive, _ = _wait_livez(url, 5)
    if alive:
        return url
    pytest.skip(
        "Edge no-bundle container not alive at {}. Run: docker compose -f tests/e2e/docker-compose.test.yml up -d".format(url)
    )


@pytest.fixture(scope="session")
def edge_reverse_base_url():
    """Base URL of reverse-proxy profile container."""
    url = EDGE_REVERSE_URL
    ready, _ = _wait_ready(url, HEALTH_TIMEOUT_S)
    if ready:
        return url
    pytest.skip(
        "Edge reverse container not ready at {}. Run: docker compose -f tests/e2e/docker-compose.test.yml up -d".format(url)
    )


@pytest.fixture(scope="session")
def edge_asn_base_url():
    """Base URL of ASN type mapping profile container."""
    url = EDGE_ASN_URL
    ready, _ = _wait_ready(url, HEALTH_TIMEOUT_S)
    if ready:
        return url
    pytest.skip(
        "Edge ASN container not ready at {}. Run: docker compose -f tests/e2e/docker-compose.test.yml up -d".format(url)
    )

