#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Phase 2: トポロジ確認 + デモ用テーブル作成 ==="

node="$(first_running_node)"
echo "使うエンドポイント: ${node}"

echo ""
echo "--- yb_servers() ---"
demo_ysql "${node}" "SELECT host, port, node_type, cloud, region, zone FROM yb_servers() ORDER BY host;"

echo ""
echo "--- テーブル ${YB_TABLE} を作成 ---"
demo_ysql "${node}" <<SQL
DROP TABLE IF EXISTS ${YB_TABLE};
CREATE TABLE ${YB_TABLE} (
  id BIGSERIAL PRIMARY KEY,
  tag TEXT NOT NULL,
  client_id INT,
  n INT,
  payload TEXT DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL

echo ""
echo "--- tablet Leader の例（yb-admin list_tablets） ---"
yb_admin "list_tablets ysql.${YB_DB} ${YB_TABLE}" || true

leader="$(find_tablet_leader_container "${YB_TABLE}")"
echo "解決した tablet Leader コンテナ（best-effort）: ${leader}"

echo "Phase 2 完了。"
