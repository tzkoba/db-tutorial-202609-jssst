#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_containers

section "Phase 4: 同じネスト更新（部分更新の書き味）"

subsection "顧客名を変更: ORD-1001 の customer.name"
cat <<'EOF'
やりたいこと: ORD-1001 の customer.name だけを "Sato H." に変える
EOF

echo "[PostgreSQL] jsonb_set でパス指定更新"
pg_sql "UPDATE orders
SET doc = jsonb_set(doc, '{customer,name}', '\"Sato H.\"'::jsonb, true)
WHERE order_id = 'ORD-1001';
SELECT order_id, doc->'customer' AS customer FROM orders WHERE order_id = 'ORD-1001';"

echo "[MongoDB] \$set + ドット記法"
mongo_eval "
const dbn = db.getSiblingDB('${MONGO_DB}');
dbn.${MONGO_COLL}.updateOne(
  { order_id: 'ORD-1001' },
  { \$set: { 'customer.name': 'Sato H.' } }
);
printjson(
  dbn.${MONGO_COLL}.find(
    { order_id: 'ORD-1001' },
    { _id: 0, order_id: 1, customer: 1 }
  ).toArray()
);
"

subsection "配列要素の数量を増やす: ORD-1002 の BOOK-2 qty を +1"
echo "[PostgreSQL] jsonb 配列の書き換えはやや冗長（要素特定→再構築）"
pg_psql <<'SQL'
WITH updated AS (
  SELECT order_id,
         jsonb_agg(
           CASE
             WHEN elem->>'sku' = 'BOOK-2'
               THEN jsonb_set(elem, '{qty}', to_jsonb((elem->>'qty')::int + 1))
             ELSE elem
           END
           ORDER BY ordinality
         ) AS new_items
  FROM orders,
       jsonb_array_elements(doc->'items') WITH ORDINALITY AS t(elem, ordinality)
  WHERE order_id = 'ORD-1002'
  GROUP BY order_id
)
UPDATE orders o
SET doc = jsonb_set(o.doc, '{items}', u.new_items)
FROM updated u
WHERE o.order_id = u.order_id;

SELECT order_id, doc->'items' AS items FROM orders WHERE order_id = 'ORD-1002';
SQL

echo "[MongoDB] \$inc と配列フィルタ（arrayFilters）"
mongo_eval "
const dbn = db.getSiblingDB('${MONGO_DB}');
dbn.${MONGO_COLL}.updateOne(
  { order_id: 'ORD-1002' },
  { \$inc: { 'items.\$[it].qty': 1 } },
  { arrayFilters: [ { 'it.sku': 'BOOK-2' } ] }
);
printjson(
  dbn.${MONGO_COLL}.find(
    { order_id: 'ORD-1002' },
    { _id: 0, order_id: 1, items: 1 }
  ).toArray()
);
"

section "対比まとめ（更新）"
cat <<'EOF'
| 観点 | PostgreSQL (jsonb) | MongoDB |
|------|--------------------|---------|
| 単純なネスト更新 | `jsonb_set(doc, path, value)` | `$set: { 'a.b': value }` |
| 配列要素の部分更新 | SQL で展開・再集約が必要なことが多い | `$inc` + `arrayFilters` などが用意されている |
| 書き味 | 「行の jsonb 列を関数で書き換える」 | 「ドキュメント内のパスを直接更新する」 |
EOF

echo "Phase 4 complete."
