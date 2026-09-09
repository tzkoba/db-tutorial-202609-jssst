#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

"${SCRIPT_DIR}/00-preflight.sh"

if docker ps -a --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "コンテナ ${PG_CONTAINER} は既に存在します。先に cleanup.sh を実行してください。"
  exit 1
fi

echo "アーカイブとバックアップのマウント付きで ${PG_CONTAINER} を起動しています…"
demo_run docker run -d --name "${PG_CONTAINER}" \
  -e POSTGRES_PASSWORD="${PG_SUPERUSER_PASSWORD}" \
  -p "${PG_PORT}:5432" \
  -v "${PG_DATA_VOLUME}:${PG_VOLUME_MOUNT}" \
  -v "${PG_ARCHIVE_VOLUME}:/archive" \
  -v "${PG_BACKUP_VOLUME}:/backup" \
  "${PG_IMAGE}"

echo "PostgreSQL の起動を待っています…"
wait_for_postgres "${PG_CONTAINER}"
chown_extra_mounts

echo "WAL アーカイブを有効にしています（後の PITR で必要）…"
demo_psql "${PG_CONTAINER}" <<'SQL'
ALTER SYSTEM SET wal_level TO 'replica';
ALTER SYSTEM SET archive_mode TO 'on';
ALTER SYSTEM SET archive_command TO 'test ! -f /archive/%f && cp %p /archive/%f';
SQL

demo_run docker restart "${PG_CONTAINER}"
wait_for_postgres "${PG_CONTAINER}"

echo "デモ用テーブルを作成しています…"
demo_psql "${PG_CONTAINER}" <<'SQL'
CREATE TABLE IF NOT EXISTS demo_items (
  id serial PRIMARY KEY,
  name text,
  created_at timestamptz DEFAULT now()
);
INSERT INTO demo_items (name)
SELECT 'initial'
WHERE NOT EXISTS (SELECT 1 FROM demo_items WHERE name = 'initial');
SQL

demo_psql "${PG_CONTAINER}" "SHOW archive_mode;"
demo_psql "${PG_CONTAINER}" "SHOW wal_level;"
demo_psql "${PG_CONTAINER}" "SELECT * FROM demo_items ORDER BY id;"

echo "Phase 1 完了。"
