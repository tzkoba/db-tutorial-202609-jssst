#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"

docker rm -f "${PG_PITR_CONTAINER}" 2>/dev/null || true
docker rm -f "${PG_CONTAINER}" 2>/dev/null || true
rm -f "${SCRIPT_DIR}/.recovery_target_time"

read -r -p "Remove volumes (${PG_DATA_VOLUME}, ${PG_PITR_DATA_VOLUME}, ${PG_ARCHIVE_VOLUME}, ${PG_BACKUP_VOLUME})? [y/N] " answer
if [[ "${answer}" =~ ^[Yy]$ ]]; then
  docker volume rm "${PG_DATA_VOLUME}" 2>/dev/null || true
  docker volume rm "${PG_PITR_DATA_VOLUME}" 2>/dev/null || true
  docker volume rm "${PG_ARCHIVE_VOLUME}" 2>/dev/null || true
  docker volume rm "${PG_BACKUP_VOLUME}" 2>/dev/null || true
  echo "Volumes removed."
else
  echo "Volumes kept."
fi

echo "Cleanup complete."
