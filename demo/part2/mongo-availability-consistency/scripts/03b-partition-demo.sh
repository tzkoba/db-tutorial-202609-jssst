#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Phase 3.5: Network Partition (docker network disconnect) ==="

primary="$(wait_for_primary)"
echo "Current PRIMARY: ${primary}"

others=()
for node in "${MONGO1}" "${MONGO2}" "${MONGO3}"; do
  [[ "${node}" == "${primary}" ]] && continue
  others+=("${node}")
done
echo "Other nodes: ${others[*]}"

echo ""
echo "--- Disconnecting PRIMARY (${primary}) from ${MONGO_NETWORK} ---"
demo_run docker network disconnect "${MONGO_NETWORK}" "${primary}"

echo "Waiting for majority side to elect a new PRIMARY..."
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
  echo "ERROR: No new PRIMARY elected on majority side within timeout."
  echo "Reconnecting ${primary} and aborting."
  docker network connect "${MONGO_NETWORK}" "${primary}"
  exit 1
fi
echo "New PRIMARY on majority side: ${new_primary}"

echo ""
echo "--- Verifying: majority side can accept writes ---"
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
echo "--- Verifying: partitioned node (${primary}) has stepped down ---"
demo_mongosh "${primary}" '
try { print(rs.isMaster().ismaster ? "still_primary" : "stepped_down"); } catch(e) { print("unreachable_or_error"); }
' "test"

echo ""
echo "--- Reconnecting ${primary} to ${MONGO_NETWORK} ---"
demo_run docker network connect "${MONGO_NETWORK}" "${primary}"

echo "Waiting for rejoined node to catch up..."
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
echo "=== Phase 3.5 Summary ==="
echo "1. PRIMARY was isolated via network disconnect (node alive, network unreachable)"
echo "2. Majority elected new PRIMARY and accepted writes (CAP: A-side)"
echo "3. Partitioned node stepped down (minority loses PRIMARY)"
echo "4. After reconnect, former PRIMARY rejoined and caught up via oplog"
echo ""
echo "Phase 3.5 complete."
