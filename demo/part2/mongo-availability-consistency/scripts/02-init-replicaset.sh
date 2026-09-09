#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../../demo-lib.sh
source "${SCRIPT_DIR}/../../../demo-lib.sh"

echo "Replica Set ${MONGO_RS} を初期化しています…"
demo_mongosh "${MONGO1}" "
printjson(rs.initiate({
  _id: '${MONGO_RS}',
  members: [
    { _id: 0, host: '${MONGO1}:27017' },
    { _id: 1, host: '${MONGO2}:27017' },
    { _id: 2, host: '${MONGO3}:27017' }
  ]
}))
" "test"

echo "PRIMARY を待っています…"
until docker exec "${MONGO1}" mongosh --quiet --eval 'rs.isMaster().ismaster || rs.isMaster().primary' 2>/dev/null | grep -Eq 'true|mongo'; do
  primary="$(docker exec "${MONGO1}" mongosh --quiet --eval 'rs.isMaster().primary' 2>/dev/null || true)"
  if [[ -n "${primary}" && "${primary}" != "null" ]]; then
    break
  fi
  sleep 1
done

sleep 2
echo "Replica Set の状態:"
demo_mongosh "${MONGO1}" 'print(JSON.stringify(rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr})), null, 2))' "test"

echo "Phase 2 完了。"
