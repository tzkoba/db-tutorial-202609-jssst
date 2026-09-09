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
  echo "コンテナ ${PG_CONTAINER} が動いていません。先に 01-start-instance.sh を実行してください。"
  exit 1
fi

echo "コミット済みの行を INSERT しています…"
demo_psql "${PG_CONTAINER}" "INSERT INTO demo_items (name) VALUES ('committed_before_crash');"

echo "未コミットのトランザクションをバックグラウンドで開始しています…"
echo
echo "# ${PG_CONTAINER}"
demo_print_sql "BEGIN; INSERT INTO demo_items (name) VALUES ('uncommitted_before_crash'); SELECT pg_sleep(120);"
docker exec -i "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -d postgres -v ON_ERROR_STOP=1 \
  -c "BEGIN; INSERT INTO demo_items (name) VALUES ('uncommitted_before_crash'); SELECT pg_sleep(120);" &
sleep 2

echo "クラッシュを模擬しています（SIGKILL）…"
demo_run docker kill -s KILL "${PG_CONTAINER}"
wait || true

echo "${PG_CONTAINER} を再起動しています…"
demo_run docker start "${PG_CONTAINER}"
wait_for_postgres "${PG_CONTAINER}"

echo "直近のログ（リカバリ）:"
demo_cmd docker logs "${PG_CONTAINER}"
docker logs "${PG_CONTAINER}" 2>&1 | tail -20

echo "クラッシュデモ関連の行:"
demo_psql "${PG_CONTAINER}" "SELECT * FROM demo_items WHERE name LIKE '%crash%' ORDER BY id;"

if docker exec "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc \
  "SELECT count(*) FROM demo_items WHERE name = 'uncommitted_before_crash';" | grep -qx "0"; then
  echo "想定どおり、未コミットの行はありません。"
else
  echo "未コミットの行は無い想定でした。"
  exit 1
fi

if ! docker exec "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc \
  "SELECT count(*) FROM demo_items WHERE name = 'committed_before_crash';" | grep -qx "1"; then
  echo "コミット済みの行はクラッシュリカバリ後も残る想定でした。"
  exit 1
fi

echo "Phase 3 完了。"
