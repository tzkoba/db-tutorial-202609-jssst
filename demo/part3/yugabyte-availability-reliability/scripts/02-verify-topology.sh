#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Phase 2: Verify topology + create demo table ==="

node="$(first_running_node)"
echo "Using endpoint: ${node}"

echo ""
echo "--- yb_servers() ---"
demo_ysql "${node}" "SELECT host, port, node_type, cloud, region, zone FROM yb_servers() ORDER BY host;"

echo ""
echo "--- Creating table ${YB_TABLE} ---"
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
echo "--- Sample tablet leaders (yb-admin list_tablets) ---"
yb_admin "list_tablets ysql.${YB_DB} ${YB_TABLE}" || true

leader="$(find_tablet_leader_container "${YB_TABLE}")"
echo "Resolved tablet Leader container (best-effort): ${leader}"

echo "Phase 2 complete."
