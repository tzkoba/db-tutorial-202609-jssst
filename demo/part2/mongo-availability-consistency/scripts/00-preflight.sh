#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"

echo "Checking Docker..."
docker version >/dev/null

echo "Creating network and run directory..."
docker network create "${MONGO_NETWORK}" 2>/dev/null || true
mkdir -p "${RUN_DIR}"

echo "Preflight complete."
