#!/usr/bin/env bash
set -euo pipefail

CLI_IMAGE="${FAIRVISOR_CLI_IMAGE:-}"
FILES=()

while IFS= read -r file; do
  FILES+=("${file}")
done < <(find examples tests/e2e -type f -name "*.json" | sort)

if [[ "${#FILES[@]}" -eq 0 ]]; then
  echo "no policy JSON files found"
  exit 1
fi

echo "[policy] syntax + shape validation"
for file in "${FILES[@]}"; do
  python3 - "$file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    payload = json.load(f)

if not isinstance(payload, dict):
    raise SystemExit(f"{path}: top-level must be an object")

policies = payload.get("policies")
if not isinstance(policies, list):
    raise SystemExit(f"{path}: 'policies' must be an array")
PY
done

if [[ -n "${CLI_IMAGE}" ]]; then
  echo "[policy] semantic validation with fairvisor CLI image ${CLI_IMAGE}"
  for file in "${FILES[@]}"; do
    docker run --rm -v "${PWD}:/work" -w /work "${CLI_IMAGE}" validate "${file}"
  done
  exit 0
fi

if command -v resty >/dev/null 2>&1; then
  echo "[policy] semantic validation with local fairvisor CLI"
  for file in "${FILES[@]}"; do
    ./bin/fairvisor validate "${file}"
  done
  exit 0
fi

echo "[policy] semantic validation skipped (no FAIRVISOR_CLI_IMAGE and no local resty)"
