#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_PRIMARY}"; then
  echo "primary コンテナ ${PG_PRIMARY} が動いていません。先に 01-start-primary.sh を実行してください。"
  exit 1
fi
if ! docker ps --format '{{.Names}}' | grep -qx "${PG_STANDBY}"; then
  echo "standby コンテナ ${PG_STANDBY} が動いていません。先に 04-start-standby.sh を実行してください。"
  exit 1
fi

echo "primary だけ同期レプリケーションを有効にしています（standby の WAL flush）…"
demo_psql "${PG_PRIMARY}" <<'SQL'
ALTER SYSTEM SET synchronous_commit TO 'on';
ALTER SYSTEM SET synchronous_standby_names TO '*';
SELECT pg_reload_conf();
SQL

echo "pg_stat_replication.sync_state = sync になるまで待っています…"
sync_state=""
for _ in $(seq 1 30); do
  sync_state="$(docker exec "${PG_PRIMARY}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc \
    "SELECT COALESCE(sync_state, '') FROM pg_stat_replication LIMIT 1;" | tr -d '\r')"
  if [[ "${sync_state}" == "sync" ]]; then
    break
  fi
  sleep 1
done
if [[ "${sync_state}" != "sync" ]]; then
  echo "同期 standby 待ちがタイムアウトしました（sync_state='${sync_state}'）。" >&2
  demo_psql "${PG_PRIMARY}" "SELECT pid, application_name, state, sync_state FROM pg_stat_replication;"
  exit 1
fi

demo_psql "${PG_PRIMARY}" <<'SQL'
SHOW synchronous_commit;
SHOW synchronous_standby_names;
SELECT pid, usename, application_name, state, sync_state
FROM pg_stat_replication;
SQL

echo "Phase 4.5 完了（primary は同期、standby の設定は変更なし）。"
