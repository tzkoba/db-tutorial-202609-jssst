#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "Container ${PG_CONTAINER} is not running."
  exit 1
fi

echo "Forcing WAL switch..."
demo_psql "${PG_CONTAINER}" "SELECT pg_switch_wal();"

echo "Archiver status:"
demo_psql "${PG_CONTAINER}" "SELECT archived_count, last_archived_wal, failed_count, last_failed_wal FROM pg_stat_archiver;"

echo "Waiting for an archived WAL file..."
count=0
for _ in $(seq 1 30); do
  count="$(docker exec "${PG_CONTAINER}" bash -c 'ls -1 /archive 2>/dev/null | wc -l' | tr -d '[:space:]')"
  if [[ "${count}" -ge 1 ]]; then
    break
  fi
  sleep 1
done

echo "Archived WAL files:"
demo_cmd docker exec "${PG_CONTAINER}" ls -l /archive
docker exec "${PG_CONTAINER}" ls -l /archive | tail -10

if [[ "${count}" -lt 1 ]]; then
  echo "Expected at least one archived WAL file. Archiver status:" >&2
  demo_psql "${PG_CONTAINER}" "SELECT archived_count, last_archived_wal, failed_count, last_failed_wal, last_failed_time FROM pg_stat_archiver;" >&2
  exit 1
fi

echo "Phase 4 complete."
