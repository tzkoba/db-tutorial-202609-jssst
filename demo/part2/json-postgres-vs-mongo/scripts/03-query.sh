#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_containers

section "Phase 3: 同じ条件で取り出す（ネスト／配列クエリ）"

subsection "ケース A: 顧客メールで1件取得"
cat <<'EOF'
欲しい結果: customer.email = sato@example.com の注文
EOF

echo "[PostgreSQL]"
pg_sql "SELECT order_id, doc #>> '{customer,name}' AS customer_name
FROM orders
WHERE doc #>> '{customer,email}' = 'sato@example.com';"

echo "[MongoDB]"
mongo_eval "
const dbn = db.getSiblingDB('${MONGO_DB}');
printjson(
  dbn.${MONGO_COLL}.find(
    { 'customer.email': 'sato@example.com' },
    { _id: 0, order_id: 1, 'customer.name': 1 }
  ).toArray()
);
"

subsection "ケース B: 配列内 SKU を含む注文（items に BOOK-2）"
echo "[PostgreSQL] jsonb 包含演算子 @>"
pg_sql "SELECT order_id
FROM orders
WHERE doc @> '{\"items\":[{\"sku\":\"BOOK-2\"}]}'::jsonb
ORDER BY order_id;"

echo "[MongoDB] ドット記法で配列要素を辿る"
mongo_eval "
const dbn = db.getSiblingDB('${MONGO_DB}');
printjson(
  dbn.${MONGO_COLL}.find(
    { 'items.sku': 'BOOK-2' },
    { _id: 0, order_id: 1 }
  ).sort({ order_id: 1 }).toArray()
);
"

subsection "ケース C: ネスト条件の AND（status=paid かつ tier=gold）"
echo "[PostgreSQL]"
pg_sql "SELECT order_id,
       doc->>'status' AS status,
       doc #>> '{customer,tier}' AS tier
FROM orders
WHERE doc->>'status' = 'paid'
  AND doc #>> '{customer,tier}' = 'gold'
ORDER BY order_id;"

echo "[MongoDB]"
mongo_eval "
const dbn = db.getSiblingDB('${MONGO_DB}');
printjson(
  dbn.${MONGO_COLL}.find(
    { status: 'paid', 'customer.tier': 'gold' },
    { _id: 0, order_id: 1, status: 1, 'customer.tier': 1 }
  ).sort({ order_id: 1 }).toArray()
);
"

subsection "ケース D: プロジェクション（返す形を絞る）"
echo "[PostgreSQL] SQL で列／式を組み立てる"
pg_sql "SELECT order_id,
       doc->'customer'->>'name' AS name,
       jsonb_array_length(doc->'items') AS item_count
FROM orders
ORDER BY order_id;"

echo "[MongoDB] プロジェクション文書でフィールドを選ぶ"
mongo_eval "
const dbn = db.getSiblingDB('${MONGO_DB}');
printjson(
  dbn.${MONGO_COLL}.aggregate([
    { \$project: {
        _id: 0,
        order_id: 1,
        name: '\$customer.name',
        item_count: { \$size: '\$items' }
    }},
    { \$sort: { order_id: 1 } }
  ]).toArray()
);
"

section "対比まとめ（取出）"
cat <<'EOF'
| 観点 | PostgreSQL (jsonb) | MongoDB |
|------|--------------------|---------|
| ネスト参照 | `->` / `->>` / `#>>` 演算子 | ドット記法 `'customer.email'` |
| 配列内マッチ | `@>` や `jsonb_path_query` など | `'items.sku': value` |
| 複合条件 | SQL の AND/OR | フィルタ文書の並記 / `$and` |
| 返す形 | SELECT リストで組み立て | projection / `$project` |
| 学習コスト | SQL + jsonb 演算子の両方 | ドキュメントフィルタに統一 |
EOF

echo "Phase 3 完了。"
