#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

section "Phase 0: Preflight"

echo "Checking Docker..."
docker version >/dev/null

if [[ ! -f "${DATA_FILE}" ]]; then
  echo "Missing sample data: ${DATA_FILE}" >&2
  exit 1
fi

echo "Creating network ${DEMO_NETWORK} (if missing)..."
docker network create "${DEMO_NETWORK}" 2>/dev/null || true

echo "Sample JSON: ${DATA_FILE}"
echo "Preflight complete."
