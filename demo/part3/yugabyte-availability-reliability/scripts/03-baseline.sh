#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Phase 3: Baseline (healthy cluster INSERT) ==="

node="$(wait_for_writable_endpoint)"
echo "Writable endpoint: ${node}"

demo_ysql "${node}" \
  "INSERT INTO ${YB_TABLE}(tag, client_id, n, payload) VALUES ('baseline', 0, 0, 'healthy') RETURNING id, tag;"

count="$(count_rows "${node}" "tag = 'baseline'")"
echo "baseline row count: ${count}"

leader="$(find_tablet_leader_container)"
echo "Current tablet Leader (best-effort): ${leader}"

echo "Phase 3 complete."
