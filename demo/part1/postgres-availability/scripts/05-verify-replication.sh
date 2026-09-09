#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_PRIMARY}"; then
  echo "primary コンテナ ${PG_PRIMARY} が動いていません。"
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_STANDBY}"; then
  echo "standby コンテナ ${PG_STANDBY} が動いていません。先に 04-start-standby.sh を実行してください。"
  exit 1
fi

sync_state="$(docker exec "${PG_PRIMARY}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc \
  "SELECT COALESCE(sync_state, '') FROM pg_stat_replication LIMIT 1;" | tr -d '\r')"
if [[ "${sync_state}" != "sync" ]]; then
  echo "standby が同期になっていません（sync_state='${sync_state}'）。先に 04b-enable-sync.sh を実行してください。"
  exit 1
fi

echo "primary の同期設定:"
demo_psql "${PG_PRIMARY}" <<'SQL'
SHOW synchronous_commit;
SHOW synchronous_standby_names;
SELECT pid, application_name, state, sync_state FROM pg_stat_replication;
SQL

echo "primary に行を INSERT しています…"
demo_psql "${PG_PRIMARY}" "INSERT INTO demo_items (name) VALUES ('after_replication');"

echo "standby から行を読んでいます…"
demo_psql "${PG_STANDBY}" "SELECT * FROM demo_items ORDER BY id;"

echo "standby が書き込みを拒否することを確認しています…"
if demo_psql_allow_fail "${PG_STANDBY}" "INSERT INTO demo_items (name) VALUES ('should_fail');"; then
  echo "standby への書き込みは失敗する想定でしたが、成功してしまいました。"
  exit 1
fi
echo "想定どおり、standby への書き込みは拒否されました。"

echo "任意のラグ確認:"
demo_psql "${PG_PRIMARY}" "SELECT pg_current_wal_lsn();"
demo_psql "${PG_STANDBY}" "SELECT pg_last_wal_replay_lsn();"

echo "Phase 5 完了。"
