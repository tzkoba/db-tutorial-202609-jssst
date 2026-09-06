#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"

echo "Stopping and removing containers..."
docker rm -f "${PG_STANDBY}" 2>/dev/null || true
docker rm -f "${PG_PRIMARY}" 2>/dev/null || true

read -r -p "Remove volumes ${PG_PRIMARY_VOLUME} and ${PG_STANDBY_VOLUME}? [y/N] " answer
if [[ "${answer}" =~ ^[Yy]$ ]]; then
  docker volume rm "${PG_PRIMARY_VOLUME}" 2>/dev/null || true
  docker volume rm "${PG_STANDBY_VOLUME}" 2>/dev/null || true
  echo "Volumes removed."
else
  echo "Volumes kept."
fi

read -r -p "Remove network ${PG_NETWORK}? [y/N] " answer
if [[ "${answer}" =~ ^[Yy]$ ]]; then
  docker network rm "${PG_NETWORK}" 2>/dev/null || true
  echo "Network removed."
else
  echo "Network kept."
fi

echo "Cleanup complete."
