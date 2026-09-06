#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_containers

section "Phase 5: スキーマが後から増えたとき（柔軟性の見え方）"

subsection "新しいフィールド shipping を持つ注文を追加"
cat <<'EOF'
新しい JSON 形（一部の注文だけ配送先を持つ）を追加投入する。
両方とも「壊さずに」格納できるが、その後の扱い方が違う。
EOF

NEW_DOC='{"order_id":"ORD-2001","status":"paid","customer":{"name":"New User","email":"new@example.com","tier":"bronze"},"items":[{"sku":"BOOK-1","title":"Database Intro","qty":1,"price":3200}],"tags":["online"],"meta":{"channel":"web","coupon":null},"shipping":{"carrier":"Yamato","eta_days":2}}'

echo "[PostgreSQL] ALTER TABLE なしで jsonb に新キーを入れられる"
pg_sql "INSERT INTO orders (doc) VALUES ('${NEW_DOC}'::jsonb);
SELECT order_id, doc ? 'shipping' AS has_shipping,
       doc->'shipping' AS shipping
FROM orders
WHERE order_id = 'ORD-2001';"

echo "[MongoDB] 同様に新フィールド付きドキュメントをそのまま insert"
mongo_eval "
const dbn = db.getSiblingDB('${MONGO_DB}');
dbn.${MONGO_COLL}.insertOne(${NEW_DOC});
printjson(
  dbn.${MONGO_COLL}.find(
    { order_id: 'ORD-2001' },
    { _id: 0, order_id: 1, shipping: 1 }
  ).toArray()
);
"

subsection "新フィールドがあるものだけ検索"
echo "[PostgreSQL] キー存在: doc ? 'shipping'"
pg_sql "SELECT order_id FROM orders WHERE doc ? 'shipping' ORDER BY order_id;"

echo "[MongoDB] 存在クエリ: { shipping: { \$exists: true } }"
mongo_eval "
const dbn = db.getSiblingDB('${MONGO_DB}');
printjson(
  dbn.${MONGO_COLL}.find(
    { shipping: { \$exists: true } },
    { _id: 0, order_id: 1 }
  ).sort({ order_id: 1 }).toArray()
);
"

subsection "使い勝手の差（講義で強調したい点）"
cat <<'EOF'
共通:
  - どちらも「後からキーが増えた JSON」を追加格納できる（厳密スキーマ強制なし）

違い:
  - PostgreSQL
      - 周囲は依然として表・型・SQL。jsonb は「列の中の半構造」として扱う
      - 生成列・CHECK・JSONB Schema（拡張）などで段階的に厳しくできる
      - リレーショナル列と jsonb を混在させやすい（例: order_id を列に出す）
  - MongoDB
      - 最初からドキュメントが第一級。アプリのオブジェクトとそのまま近い
      - バリデーションを入れるなら JSON Schema をコレクションに設定する（任意）
      - 「表設計してから JSON 列」ではなく「コレクションに文書を置く」感覚

結論（デモのメッセージ）:
  PostgreSQL の jsonb は RDB の上に JSON を載せる強力な機能だが、
  ネスト更新や配列操作の API は MongoDB の方がドキュメント操作として素直な場面が多い。
  一方、結合・制約・既存 SQL 資産と混ぜるなら PostgreSQL 側が有利、という使い分けが見える。
EOF

echo "Phase 5 complete."
