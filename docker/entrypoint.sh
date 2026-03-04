#!/usr/bin/env bash
set -eu

if [ -n "${FAIRVISOR_SAAS_URL:-}" ]; then
  if [ -z "${FAIRVISOR_EDGE_ID:-}" ]; then
    echo "fairvisor: FAIRVISOR_EDGE_ID is required when FAIRVISOR_SAAS_URL is set" >&2
    exit 1
  fi
  if [ -z "${FAIRVISOR_EDGE_TOKEN:-}" ]; then
    echo "fairvisor: FAIRVISOR_EDGE_TOKEN is required when FAIRVISOR_SAAS_URL is set" >&2
    exit 1
  fi
fi

if [ -z "${FAIRVISOR_SAAS_URL:-}" ] && [ -z "${FAIRVISOR_CONFIG_FILE:-}" ]; then
  echo "fairvisor: set FAIRVISOR_SAAS_URL (SaaS mode) or FAIRVISOR_CONFIG_FILE (standalone mode)" >&2
  exit 1
fi

if [ "${FAIRVISOR_MODE:-decision_service}" != "decision_service" ] && [ "${FAIRVISOR_MODE:-decision_service}" != "reverse_proxy" ]; then
  echo "fairvisor: FAIRVISOR_MODE must be decision_service or reverse_proxy" >&2
  exit 1
fi

if [ "${FAIRVISOR_MODE:-decision_service}" = "reverse_proxy" ] && [ -z "${FAIRVISOR_BACKEND_URL:-}" ]; then
  echo "fairvisor: FAIRVISOR_BACKEND_URL is required when FAIRVISOR_MODE=reverse_proxy" >&2
  exit 1
fi

: "${FAIRVISOR_SHARED_DICT_SIZE:=128m}"
: "${FAIRVISOR_LOG_LEVEL:=info}"
: "${FAIRVISOR_MODE:=decision_service}"
: "${FAIRVISOR_CONFIG_POLL_INTERVAL:=30}"
: "${FAIRVISOR_HEARTBEAT_INTERVAL:=5}"
: "${FAIRVISOR_EVENT_FLUSH_INTERVAL:=60}"
: "${FAIRVISOR_BACKEND_URL:=http://127.0.0.1:8081}"
: "${FAIRVISOR_WORKER_PROCESSES:=auto}"

export FAIRVISOR_SHARED_DICT_SIZE
export FAIRVISOR_LOG_LEVEL
export FAIRVISOR_MODE
export FAIRVISOR_CONFIG_POLL_INTERVAL
export FAIRVISOR_HEARTBEAT_INTERVAL
export FAIRVISOR_EVENT_FLUSH_INTERVAL
export FAIRVISOR_BACKEND_URL
export FAIRVISOR_WORKER_PROCESSES

envsubst '${FAIRVISOR_SHARED_DICT_SIZE} ${FAIRVISOR_LOG_LEVEL} ${FAIRVISOR_MODE} ${FAIRVISOR_BACKEND_URL} ${FAIRVISOR_WORKER_PROCESSES}' \
  < /opt/fairvisor/nginx.conf.template \
  > /usr/local/openresty/nginx/conf/nginx.conf

exec openresty -g 'daemon off;' -c /usr/local/openresty/nginx/conf/nginx.conf
