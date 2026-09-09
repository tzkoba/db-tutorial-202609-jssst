#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_STANDBY}"; then
  echo "standby コンテナ ${PG_STANDBY} が動いていません。先に 04-start-standby.sh を実行してください。"
  exit 1
fi

if docker ps --format '{{.Names}}' | grep -qx "${PG_PRIMARY}"; then
  echo "primary ${PG_PRIMARY} を停止しています…"
  demo_run docker stop "${PG_PRIMARY}"
fi

echo "standby を昇格しています…"
demo_psql "${PG_STANDBY}" "SELECT pg_promote();"

echo "昇格が完了するまで待っています…"
until docker exec "${PG_STANDBY}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc "SELECT pg_is_in_recovery();" | grep -qx "f"; do
  sleep 1
done

echo "昇格したノードには synchronous_standby_names がありません（旧 primary にだけ設定していました）。"
echo "旧 primary は止めたままです（1 台での縮退運転）。"
demo_psql "${PG_STANDBY}" <<'SQL'
SHOW synchronous_standby_names;
INSERT INTO demo_items (name) VALUES ('after_failover');
SELECT * FROM demo_items ORDER BY id;
SQL

echo "Phase 6 完了。"
