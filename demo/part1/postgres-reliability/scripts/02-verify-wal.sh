#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "Container ${PG_CONTAINER} is not running. Run 01-start-instance.sh first."
  exit 1
fi

echo "LSN before INSERT:"
demo_psql "${PG_CONTAINER}" "SELECT pg_current_wal_lsn();"

echo "Inserting row..."
demo_psql "${PG_CONTAINER}" "INSERT INTO demo_items (name) VALUES ('after_wal_demo');"

echo "LSN after INSERT:"
demo_psql "${PG_CONTAINER}" "SELECT pg_current_wal_lsn();"

echo "WAL segment files:"
demo_cmd docker exec "${PG_CONTAINER}" ls -l "${PG_DATA_DIR}/pg_wal"
docker exec "${PG_CONTAINER}" ls -l "${PG_DATA_DIR}/pg_wal" | head -10

echo "Phase 2 complete."
