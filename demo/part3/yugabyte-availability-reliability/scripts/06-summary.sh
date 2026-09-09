#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Phase 6: まとめ（Mongo w:1+local 対 YugabyteDB Raft commit） ==="

missing_failover="$(wc -l < "${RUN_DIR}/missing-failover.txt" 2>/dev/null | tr -d ' ' || echo 0)"
success_failover="$(grep -cve '^$' "${RUN_DIR}/success-failover.txt" 2>/dev/null || echo 0)"

ep=""
if ep="$(first_running_node 2>/dev/null)"; then
  echo "サンプルエンドポイント: ${ep}"
  total="$(count_rows "${ep}" "true" 2>/dev/null || echo "?")"
  echo "${YB_TABLE} の総行数: ${total}"
  echo ""
  echo "--- yb_servers() ---"
  demo_ysql "${ep}" "SELECT host, port, node_type FROM yb_servers() ORDER BY host;" 2>/dev/null || true
fi

cat <<EOF

記録した Phase 4 の統計:
  クライアントが ACK した COMMIT : ${success_failover}
  kill 後の MISSING           : ${missing_failover}

Takeaways（講義での Part2 MongoDB との対比）:
- MongoDB の w:1 + local 読みは、多数派の耐久コピーより先に ACK できる。PRIMARY kill で acked 書き込みが失われることがある。
- MongoDB の w:majority + readConcern majority は多数派 snapshot を待つ。生存した ACK は残る（タイムアウト時は可用性は下がることがある）。
- YugabyteDB の YSQL COMMIT は tablet 上の Raft majority 合意を意味する。このデモは
  「w:1 型の損失」経路を作らない。COMMIT 済み行は Leader tserver の kill／分断後も残る想定。
- 分断（Phase 3.5）: 隔離された少数派 Leader は安全に COMMIT できない。多数派は継続する。
- 任意の Phase 5: 複数 tablet にまたがる txn は全部成功か全部失敗（Leader が同じノードでもよい）。txn 中にそのノードを kill するとどちらにも部分行は残らない。COMMIT 後は両テーブルに行が残る。最後に Leader を再 SELECT — 各テーブルが再選出する。

デモディレクトリ: ${DEMO_DIR}
EOF

echo "Phase 6 完了。"
