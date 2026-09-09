#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Phase 3: ベースライン（健全クラスタへの INSERT） ==="

node="$(wait_for_writable_endpoint)"
echo "書き込み可能なエンドポイント: ${node}"

demo_ysql "${node}" \
  "INSERT INTO ${YB_TABLE}(tag, client_id, n, payload) VALUES ('baseline', 0, 0, 'healthy') RETURNING id, tag;"

count="$(count_rows "${node}" "tag = 'baseline'")"
echo "baseline の行数: ${count}"

leader="$(find_tablet_leader_container)"
echo "現在の tablet Leader（best-effort）: ${leader}"

echo "Phase 3 完了。"
