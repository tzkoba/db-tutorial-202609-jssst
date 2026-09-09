#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Phase 3.5: ネットワーク分断（docker network disconnect） ==="

primary="$(wait_for_primary)"
echo "現在の PRIMARY: ${primary}"

others=()
for node in "${MONGO1}" "${MONGO2}" "${MONGO3}"; do
  [[ "${node}" == "${primary}" ]] && continue
  others+=("${node}")
done
echo "その他のノード: ${others[*]}"

echo ""
echo "--- PRIMARY（${primary}）を ${MONGO_NETWORK} から切断 ---"
demo_run docker network disconnect "${MONGO_NETWORK}" "${primary}"

echo "多数派側が新しい PRIMARY を選出するまで待っています…"
sleep 2

new_primary=""
for i in $(seq 1 60); do
  for node in "${others[@]}"; do
    candidate="$(docker exec "${node}" mongosh --quiet --eval '
try { const m = rs.isMaster(); if (m.ismaster) print(m.me.split(":")[0]); else print(""); } catch(e) { print(""); }
' 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
    if [[ -n "${candidate}" && "${candidate}" != "${primary}" ]]; then
      new_primary="${candidate}"
      break 2
    fi
  done
  sleep 1
done

if [[ -z "${new_primary}" ]]; then
  echo "ERROR: 制限時間内に多数派側で新しい PRIMARY が選出されませんでした。"
  echo "${primary} を再接続して中止します。"
  docker network connect "${MONGO_NETWORK}" "${primary}"
  exit 1
fi
echo "多数派側の新しい PRIMARY: ${new_primary}"

echo ""
echo "--- 確認: 多数派側は書き込みを受け付ける ---"
demo_mongosh "${new_primary}" "
const dbn = db.getSiblingDB('${MONGO_DB}');
try {
  const r = dbn.${MONGO_COLL}.insertOne(
    { tag: 'partition_test', at: new Date() },
    { writeConcern: { w: 'majority', wtimeout: 10000 } }
  );
  print('OK: ' + r.insertedId);
} catch(e) { print('ERR: ' + e.message); }
" "${MONGO_DB}"

echo ""
echo "--- 確認: 分断されたノード（${primary}）は降格している ---"
demo_mongosh "${primary}" '
try { print(rs.isMaster().ismaster ? "still_primary" : "stepped_down"); } catch(e) { print("unreachable_or_error"); }
' "test"

echo ""
echo "--- ${primary} を ${MONGO_NETWORK} に再接続 ---"
demo_run docker network connect "${MONGO_NETWORK}" "${primary}"

echo "再参加したノードの追従を待っています…"
sleep 8

demo_mongosh "${primary}" '
try {
  const m = rs.isMaster();
  if (m.ismaster) print("PRIMARY");
  else if (m.secondary) print("SECONDARY");
  else print("OTHER");
} catch(e) { print("error"); }
' "test"

demo_mongosh "${primary}" "
const dbn = db.getSiblingDB('${MONGO_DB}');
print('partition_test docs=' + dbn.${MONGO_COLL}.countDocuments({ tag: 'partition_test' }));
" "${MONGO_DB}"

echo ""
echo "=== Phase 3.5 まとめ ==="
echo "1. PRIMARY をネットワーク切断で隔離した（プロセスは生きているが到達不能）"
echo "2. 多数派が新しい PRIMARY を選出し、書き込みを受け付けた（CAP: A 側）"
echo "3. 分断されたノードは降格した（少数派は PRIMARY を失う）"
echo "4. 再接続後、旧 PRIMARY は再参加し oplog で追いついた"
echo ""
echo "Phase 3.5 完了。"
