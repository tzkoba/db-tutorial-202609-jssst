#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "コンテナ ${PG_CONTAINER} が動いていません。先に 01-start-instance.sh を実行してください。"
  exit 1
fi

echo "INSERT 前の LSN:"
demo_psql "${PG_CONTAINER}" "SELECT pg_current_wal_lsn();"

echo "行を INSERT しています…"
demo_psql "${PG_CONTAINER}" "INSERT INTO demo_items (name) VALUES ('after_wal_demo');"

echo "INSERT 後の LSN:"
demo_psql "${PG_CONTAINER}" "SELECT pg_current_wal_lsn();"

echo "WAL セグメントファイル:"
demo_cmd docker exec "${PG_CONTAINER}" ls -l "${PG_DATA_DIR}/pg_wal"
docker exec "${PG_CONTAINER}" ls -l "${PG_DATA_DIR}/pg_wal" | head -10

echo "Phase 2 完了。"
