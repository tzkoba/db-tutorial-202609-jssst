#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if docker ps -a --format '{{.Names}}' | grep -qx "${PG_STANDBY}"; then
  echo "コンテナ ${PG_STANDBY} は既に存在します。起動をスキップするか、先に cleanup.sh を実行してください。"
  exit 1
fi

echo "ボリューム ${PG_STANDBY_VOLUME} 上の standby データディレクトリを確認しています…"
if ! docker run --rm \
  -e PGDATADIR="${PG_DATA_DIR}" \
  -v "${PG_STANDBY_VOLUME}:${PG_VOLUME_MOUNT}" \
  --entrypoint bash \
  "${PG_IMAGE}" \
  -c 'test -f "$PGDATADIR/standby.signal"'; then
  echo "standby のデータディレクトリが未初期化です。先に 03-init-standby.sh を実行してください。"
  exit 1
fi

# pg_basebackup as root leaves /var/lib/postgresql/18 mode 0700. The image
# entrypoint gosu's to uid 999 and then mkdir -p $PGDATA, which fails with
# "mkdir: cannot create directory '/var/lib/postgresql/18': Permission denied".
echo "postgres uid 向けにボリュームの所有者を直しています…"
docker run --rm \
  -e PGDATADIR="${PG_DATA_DIR}" \
  -e PGVOL="${PG_VOLUME_MOUNT}" \
  -v "${PG_STANDBY_VOLUME}:${PG_VOLUME_MOUNT}" \
  --entrypoint bash \
  "${PG_IMAGE}" \
  -c 'set -euo pipefail
      chown -R postgres:postgres "$PGVOL"
      chmod 0755 "$PGVOL" "$PGVOL/18"
      chmod 0700 "$PGDATADIR"'

echo "standby コンテナ ${PG_STANDBY} を起動しています…"
demo_run docker run -d --name "${PG_STANDBY}" --network "${PG_NETWORK}" \
  -p "${PG_STANDBY_PORT}:5432" \
  -v "${PG_STANDBY_VOLUME}:${PG_VOLUME_MOUNT}" \
  "${PG_IMAGE}"

echo "standby が接続を受け付けるまで待っています…"
for _ in $(seq 1 60); do
  if ! docker ps --format '{{.Names}}' | grep -qx "${PG_STANDBY}"; then
    echo "コンテナ ${PG_STANDBY} が終了しました。ログ:" >&2
    docker logs "${PG_STANDBY}" >&2 || true
    exit 1
  fi
  if docker exec "${PG_STANDBY}" pg_isready -U "${PG_SUPERUSER}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! docker exec "${PG_STANDBY}" pg_isready -U "${PG_SUPERUSER}" >/dev/null 2>&1; then
  echo "${PG_STANDBY} の起動待ちがタイムアウトしました。ログ:" >&2
  docker logs "${PG_STANDBY}" >&2 || true
  exit 1
fi

echo "standby のリカバリモード:"
demo_psql "${PG_STANDBY}" "SELECT pg_is_in_recovery();"

echo "primary のレプリケーション状態:"
demo_psql "${PG_PRIMARY}" "SELECT pid, usename, application_name, state, sync_state FROM pg_stat_replication;"

echo "standby の WAL receiver 状態:"
demo_psql "${PG_STANDBY}" "SELECT status, written_lsn, flushed_lsn, latest_end_lsn FROM pg_stat_wal_receiver;"

echo "Phase 4 完了。"
