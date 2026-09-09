#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "コンテナ ${PG_CONTAINER} が動いていません。"
  exit 1
fi

echo "WAL スイッチを強制しています…"
demo_psql "${PG_CONTAINER}" "SELECT pg_switch_wal();"

echo "アーカイバの状態:"
demo_psql "${PG_CONTAINER}" "SELECT archived_count, last_archived_wal, failed_count, last_failed_wal FROM pg_stat_archiver;"

echo "アーカイブされた WAL ファイルを待っています…"
count=0
for _ in $(seq 1 30); do
  count="$(docker exec "${PG_CONTAINER}" bash -c 'ls -1 /archive 2>/dev/null | wc -l' | tr -d '[:space:]')"
  if [[ "${count}" -ge 1 ]]; then
    break
  fi
  sleep 1
done

echo "アーカイブされた WAL ファイル:"
demo_cmd docker exec "${PG_CONTAINER}" ls -l /archive
docker exec "${PG_CONTAINER}" ls -l /archive | tail -10

if [[ "${count}" -lt 1 ]]; then
  echo "アーカイブされた WAL ファイルが 1 つ以上ある想定でした。アーカイバの状態:" >&2
  demo_psql "${PG_CONTAINER}" "SELECT archived_count, last_archived_wal, failed_count, last_failed_wal, last_failed_time FROM pg_stat_archiver;" >&2
  exit 1
fi

echo "Phase 4 完了。"
