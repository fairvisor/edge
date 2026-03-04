#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-${GITHUB_REF_NAME:-}}"
if [[ -z "${TAG}" ]]; then
  echo "release tag is required" >&2
  exit 1
fi

if [[ ! "${TAG}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "tag must match vMAJOR.MINOR.PATCH, got: ${TAG}" >&2
  exit 1
fi

VERSION="${TAG#v}"
if ! grep -Eq "^## \[(v)?${VERSION}\]" CHANGELOG.md; then
  echo "CHANGELOG.md must include section for ${VERSION} or v${VERSION}" >&2
  exit 1
fi

echo "release tag ${TAG} and changelog section are valid"
