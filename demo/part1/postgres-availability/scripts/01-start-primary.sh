#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

"${SCRIPT_DIR}/00-preflight.sh"

if docker ps -a --format '{{.Names}}' | grep -qx "${PG_PRIMARY}"; then
  echo "コンテナ ${PG_PRIMARY} は既に存在します。起動をスキップするか、先に cleanup.sh を実行してください。"
  exit 1
fi

echo "primary コンテナ ${PG_PRIMARY} を起動しています…"
demo_run docker run -d --name "${PG_PRIMARY}" --network "${PG_NETWORK}" \
  -e POSTGRES_PASSWORD="${PG_SUPERUSER_PASSWORD}" \
  -p "${PG_PRIMARY_PORT}:5432" \
  -v "${PG_PRIMARY_VOLUME}:${PG_VOLUME_MOUNT}" \
  "${PG_IMAGE}"

echo "primary が接続を受け付けるまで待っています…"
until docker exec "${PG_PRIMARY}" pg_isready -U "${PG_SUPERUSER}" >/dev/null 2>&1; do
  sleep 1
done

echo "デモ用テーブルを作成しています…"
demo_psql "${PG_PRIMARY}" <<'SQL'
CREATE TABLE IF NOT EXISTS demo_items (
  id serial PRIMARY KEY,
  name text,
  created_at timestamptz DEFAULT now()
);
INSERT INTO demo_items (name)
SELECT 'before_replication'
WHERE NOT EXISTS (SELECT 1 FROM demo_items WHERE name = 'before_replication');
SQL

demo_psql "${PG_PRIMARY}" "SELECT version();"
demo_psql "${PG_PRIMARY}" "SELECT * FROM demo_items ORDER BY id;"

echo "Phase 1 完了。"
