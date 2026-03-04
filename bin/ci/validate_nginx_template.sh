#!/usr/bin/env bash
set -euo pipefail

RUNTIME_IMAGE="${FAIRVISOR_RUNTIME_IMAGE:-fairvisor-runtime-ci}"

docker run --rm \
  --entrypoint sh \
  -e "FAIRVISOR_SHARED_DICT_SIZE=${FAIRVISOR_SHARED_DICT_SIZE:-4m}" \
  -e "FAIRVISOR_LOG_LEVEL=${FAIRVISOR_LOG_LEVEL:-info}" \
  -e "FAIRVISOR_MODE=${FAIRVISOR_MODE:-decision_service}" \
  -e "FAIRVISOR_BACKEND_URL=${FAIRVISOR_BACKEND_URL:-http://127.0.0.1:8081}" \
  -e "FAIRVISOR_WORKER_PROCESSES=${FAIRVISOR_WORKER_PROCESSES:-1}" \
  "${RUNTIME_IMAGE}" -c '
  envsubst '"'"'${FAIRVISOR_SHARED_DICT_SIZE} ${FAIRVISOR_LOG_LEVEL} ${FAIRVISOR_MODE} ${FAIRVISOR_BACKEND_URL} ${FAIRVISOR_WORKER_PROCESSES}'"'"' \
    < /opt/fairvisor/nginx.conf.template \
    > /tmp/nginx.conf
  openresty -t -c /tmp/nginx.conf -p /usr/local/openresty/nginx/
'
