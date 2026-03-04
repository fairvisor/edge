#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-tests/e2e/docker-compose.test.yml}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts/e2e-full}"

mkdir -p "${ARTIFACTS_DIR}"

cleanup() {
  docker compose -f "${COMPOSE_FILE}" logs --no-color > "${ARTIFACTS_DIR}/compose.log" || true
  docker compose -f "${COMPOSE_FILE}" down -v || true
}
trap cleanup EXIT

docker compose -f "${COMPOSE_FILE}" up -d --build

pytest tests/e2e -v --junitxml="${ARTIFACTS_DIR}/junit.xml"
