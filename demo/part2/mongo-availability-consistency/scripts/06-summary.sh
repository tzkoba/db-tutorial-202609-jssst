#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Summary ==="
echo "w:1 missing count: $(wc -l < "${RUN_DIR}/missing-w1.txt" 2>/dev/null || echo 0)"
echo "w:majority missing count: $(wc -l < "${RUN_DIR}/missing-majority.txt" 2>/dev/null || echo 0)"

primary="$(wait_for_primary || true)"
if [[ -n "${primary:-}" ]]; then
  echo "Current PRIMARY: ${primary}"
  demo_mongosh "${primary}" "
const dbn = db.getSiblingDB('${MONGO_DB}');
print('total docs=' + dbn.${MONGO_COLL}.countDocuments({}));
printjson(rs.status().members.map(m => ({ name: m.name, stateStr: m.stateStr })));
" "${MONGO_DB}"
fi

cat <<'EOF'

Takeaways:
- w:1 + local reads can acknowledge before a majority has the write; failover may roll it back (acked write loss).
- w:majority + readConcern majority is the consistency-oriented pairing; surviving acks should remain after failover.
- Read Preference chooses where to read; Write/Read Concern choose durability/consistency strength.
EOF

echo "Phase 6 complete."
