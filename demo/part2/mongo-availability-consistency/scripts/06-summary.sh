#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== まとめ ==="
echo "w:1 の MISSING 件数: $(wc -l < "${RUN_DIR}/missing-w1.txt" 2>/dev/null || echo 0)"
echo "w:majority の MISSING 件数: $(wc -l < "${RUN_DIR}/missing-majority.txt" 2>/dev/null || echo 0)"

primary="$(wait_for_primary || true)"
if [[ -n "${primary:-}" ]]; then
  echo "現在の PRIMARY: ${primary}"
  demo_mongosh "${primary}" "
const dbn = db.getSiblingDB('${MONGO_DB}');
print('total docs=' + dbn.${MONGO_COLL}.countDocuments({}));
printjson(rs.status().members.map(m => ({ name: m.name, stateStr: m.stateStr })));
" "${MONGO_DB}"
fi

cat <<'EOF'

Takeaways:
- w:1 + local 読みは、多数派が書き込みを持つ前に ACK できる。フェイルオーバーで巻き戻る（acked 書き込みの損失）ことがある。
- w:majority + readConcern majority は一貫性寄りの組み合わせ。生存した ACK はフェイルオーバー後も残る想定。
- Read Preference は「どこから読むか」、Write/Read Concern は耐久性／一貫性の強さ。
EOF

echo "Phase 6 完了。"
