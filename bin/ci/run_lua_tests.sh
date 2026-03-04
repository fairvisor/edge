#!/usr/bin/env bash
set -euo pipefail

echo "[lua] luacheck"
luacheck src cli spec

echo "[lua] busted unit"
busted spec/unit/

echo "[lua] busted integration"
busted spec/integration/
