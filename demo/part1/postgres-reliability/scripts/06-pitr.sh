#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "コンテナ ${PG_CONTAINER} が動いていません。"
  exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/.recovery_target_time" ]]; then
  echo "リカバリ目標時刻が見つかりません。先に 05-basebackup.sh を実行してください。"
  exit 1
fi

RECOVERY_TARGET="$(tr -d '\r\n' < "${SCRIPT_DIR}/.recovery_target_time")"
PGDATA_PARENT="$(dirname "${PG_DATA_DIR}")"

echo "誤った DELETE を模擬しています…"
demo_psql "${PG_CONTAINER}" "DELETE FROM demo_items WHERE name LIKE 'before_mistake_%';"

echo "誤操作後の行（primary 上では消えている想定）:"
demo_psql "${PG_CONTAINER}" "SELECT * FROM demo_items WHERE name LIKE 'before_mistake_%';"

demo_psql "${PG_CONTAINER}" "SELECT pg_switch_wal();"

if docker ps -a --format '{{.Names}}' | grep -qx "${PG_PITR_CONTAINER}"; then
  docker rm -f "${PG_PITR_CONTAINER}" >/dev/null
fi

echo "ベースバックアップから PITR 用データディレクトリを用意しています…"
demo_run docker run --rm \
  -e PGVOL="${PG_VOLUME_MOUNT}" \
  -e PGDATADIR="${PG_DATA_DIR}" \
  -v "${PG_BACKUP_VOLUME}:/backup:ro" \
  -v "${PG_PITR_DATA_VOLUME}:${PG_VOLUME_MOUNT}" \
  --entrypoint bash \
  "${PG_IMAGE}" \
  -c 'set -euo pipefail
      rm -rf "${PGVOL:?}/"*
      mkdir -p "$PGDATADIR"
      cp -a /backup/. "$PGDATADIR/"
      chown -R postgres:postgres "$PGVOL"
      chmod 0755 "$PGVOL" "$(dirname "$PGDATADIR")"
      chmod 0700 "$PGDATADIR"'

echo "PITR リカバリを設定しています（target: ${RECOVERY_TARGET}）…"
demo_run docker run --rm \
  -v "${PG_PITR_DATA_VOLUME}:${PG_VOLUME_MOUNT}" \
  --entrypoint bash \
  "${PG_IMAGE}" \
  -c "touch ${PG_DATA_DIR}/recovery.signal && cat >> ${PG_DATA_DIR}/postgresql.auto.conf <<EOF
restore_command = 'cp /archive/%f %p'
recovery_target_time = '${RECOVERY_TARGET}'
recovery_target_action = 'promote'
EOF
chown -R postgres:postgres ${PG_VOLUME_MOUNT}
chmod 0755 ${PG_VOLUME_MOUNT} ${PGDATA_PARENT}
chmod 0700 ${PG_DATA_DIR}"

echo "PITR 復元コンテナ ${PG_PITR_CONTAINER} をポート ${PG_PITR_PORT} で起動しています…"
demo_run docker run -d --name "${PG_PITR_CONTAINER}" \
  -p "${PG_PITR_PORT}:5432" \
  -v "${PG_PITR_DATA_VOLUME}:${PG_VOLUME_MOUNT}" \
  -v "${PG_ARCHIVE_VOLUME}:/archive:ro" \
  "${PG_IMAGE}"

echo "PITR インスタンスが接続を受け付けるまで待っています…"
wait_for_postgres "${PG_PITR_CONTAINER}" 90

echo "recovery_target_time と昇格を待っています…"
promoted=0
for _ in $(seq 1 90); do
  if ! docker ps --format '{{.Names}}' | grep -qx "${PG_PITR_CONTAINER}"; then
    echo "PITR コンテナが終了しました。ログ:" >&2
    docker logs "${PG_PITR_CONTAINER}" >&2 || true
    exit 1
  fi
  if docker exec "${PG_PITR_CONTAINER}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc \
    "SELECT pg_is_in_recovery();" 2>/dev/null | grep -qx "f"; then
    promoted=1
    break
  fi
  sleep 1
done
if [[ "${promoted}" -ne 1 ]]; then
  echo "PITR の昇格待ちがタイムアウトしました。ログ:" >&2
  docker logs "${PG_PITR_CONTAINER}" >&2 || true
  exit 1
fi

echo "PITR インスタンス上で復元された行:"
demo_psql "${PG_PITR_CONTAINER}" "SELECT * FROM demo_items WHERE name LIKE 'before_mistake_%' ORDER BY id;"

if ! docker exec "${PG_PITR_CONTAINER}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc \
  "SELECT count(*) FROM demo_items WHERE name LIKE 'before_mistake_%';" | grep -qx "2"; then
  echo "PITR インスタンス上に復元された行が 2 件ある想定でした。"
  exit 1
fi

echo "Phase 6 完了。"
