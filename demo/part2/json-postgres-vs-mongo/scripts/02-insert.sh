#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_containers
copy_sample_into_containers

section "Phase 2: 同じ JSON を格納する（DDL / Insert の使い勝手）"

subsection "PostgreSQL: 表定義が先（jsonb 列を用意）"
cat <<'EOF'
ポイント:
  - RDB なので「どこに入れるか」の器（表・列）を先に定義する
  - JSON 本体は jsonb 列に載せる（キー列を別途持つと検索しやすくなる）
EOF

pg_psql <<'SQL'
DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
  id         bigserial PRIMARY KEY,
  order_id   text GENERATED ALWAYS AS (doc->>'order_id') STORED,
  doc        jsonb NOT NULL
);
CREATE UNIQUE INDEX orders_order_id_uidx ON orders (order_id);
CREATE INDEX orders_doc_gin ON orders USING gin (doc);
SQL

subsection "PostgreSQL: 同一 JSON を jsonb として INSERT"
pg_load_sample_orders
pg_sql "SELECT order_id, jsonb_pretty(doc) AS doc FROM orders ORDER BY order_id;"

subsection "MongoDB: コレクションは初回 insert で自動生成"
cat <<'EOF'
ポイント:
  - CREATE TABLE 相当は不要。insert した瞬間にコレクションができる
  - ドキュメントそのものがレコード。別途「JSON 列」を意識しない
EOF

demo_mongosh "${MONGO_CONTAINER}" "printjson(db.getSiblingDB('${MONGO_DB}').${MONGO_COLL}.drop());" "${MONGO_DB}"
demo_run docker exec "${MONGO_CONTAINER}" mongoimport \
  --db "${MONGO_DB}" --collection "${MONGO_COLL}" \
  --file /tmp/sample-orders.json --jsonArray

mongo_eval "
const dbn = db.getSiblingDB('${MONGO_DB}');
print('count=' + dbn.${MONGO_COLL}.countDocuments({}));
printjson(dbn.${MONGO_COLL}.find({}, { _id: 0 }).sort({ order_id: 1 }).toArray());
"
section "対比まとめ（格納）"
cat <<'EOF'
| 観点 | PostgreSQL (jsonb) | MongoDB |
|------|--------------------|---------|
| 器の用意 | CREATE TABLE（列型の決定）が必要 | 不要（コレクションは暗黙） |
| 1件の単位 | 行 + jsonb 列（＋任意の生成列） | ドキュメントそのもの |
| 同じ JSON | `INSERT ... jsonb` | `insertMany(docs)` |
| 索引 | GIN on jsonb / 生成列の B-tree など | フィールドパスへ createIndex |
EOF

echo "Phase 2 完了。"
