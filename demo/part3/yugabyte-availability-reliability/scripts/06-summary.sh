#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Phase 6: Summary (Mongo w:1+local vs YugabyteDB Raft commit) ==="

missing_failover="$(wc -l < "${RUN_DIR}/missing-failover.txt" 2>/dev/null | tr -d ' ' || echo 0)"
success_failover="$(grep -cve '^$' "${RUN_DIR}/success-failover.txt" 2>/dev/null || echo 0)"

ep=""
if ep="$(first_running_node 2>/dev/null)"; then
  echo "Sample endpoint: ${ep}"
  total="$(count_rows "${ep}" "true" 2>/dev/null || echo "?")"
  echo "Total rows in ${YB_TABLE}: ${total}"
  echo ""
  echo "--- yb_servers() ---"
  demo_ysql "${ep}" "SELECT host, port, node_type FROM yb_servers() ORDER BY host;" 2>/dev/null || true
fi

cat <<EOF

Recorded Phase 4 stats:
  client-acked commits : ${success_failover}
  missing after kill   : ${missing_failover}

Takeaways (lecture contrast with Part2 MongoDB):
- MongoDB w:1 + local reads can acknowledge before a majority durable copy; Primary kill may lose acked writes.
- MongoDB w:majority + readConcern majority waits for a majority snapshot; surviving acks remain (availability may dip on timeouts).
- YugabyteDB YSQL COMMIT means Raft majority consensus on the tablet — this demo does NOT invent a
  "w:1-style loss" path. Committed rows are expected to remain after Leader tserver kill / partition.
- Partition (Phase 3.5): minority isolated Leader cannot safely commit; majority continues.
- Optional Phase 5: a cross-tablet txn is all-or-nothing (Leaders may share a node). Kill that node mid-txn and neither table keeps partial rows; after COMMIT both tables keep the rows. Re-SELECT Leaders at the end — each table re-elects.

Demo directory: ${DEMO_DIR}
EOF

echo "Phase 6 complete."
