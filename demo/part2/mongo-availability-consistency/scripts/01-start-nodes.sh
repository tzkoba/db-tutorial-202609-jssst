#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../../demo-lib.sh
source "${SCRIPT_DIR}/../../../demo-lib.sh"

"${SCRIPT_DIR}/00-preflight.sh"

for name in "${MONGO1}" "${MONGO2}" "${MONGO3}"; do
  if docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
    echo "コンテナ ${name} は既に存在します。先に cleanup.sh を実行してください。"
    exit 1
  fi
done

echo "${MONGO1} をホストポート ${MONGO1_PORT} で起動しています…"
demo_run docker run -d --name "${MONGO1}" --hostname "${MONGO1}" --network "${MONGO_NETWORK}" \
  -p "${MONGO1_PORT}:27017" \
  "${MONGO_IMAGE}" mongod --replSet "${MONGO_RS}" --bind_ip_all

echo "${MONGO2} をホストポート ${MONGO2_PORT} で起動しています…"
demo_run docker run -d --name "${MONGO2}" --hostname "${MONGO2}" --network "${MONGO_NETWORK}" \
  -p "${MONGO2_PORT}:27017" \
  "${MONGO_IMAGE}" mongod --replSet "${MONGO_RS}" --bind_ip_all

echo "${MONGO3} をホストポート ${MONGO3_PORT} で起動しています…"
demo_run docker run -d --name "${MONGO3}" --hostname "${MONGO3}" --network "${MONGO_NETWORK}" \
  -p "${MONGO3_PORT}:27017" \
  "${MONGO_IMAGE}" mongod --replSet "${MONGO_RS}" --bind_ip_all

echo "mongod が接続を受け付けるまで待っています…"
for name in "${MONGO1}" "${MONGO2}" "${MONGO3}"; do
  for _ in $(seq 1 60); do
    demo_fail_if_exited "${name}"
    if docker exec "${name}" mongosh --quiet --eval 'db.runCommand({ ping: 1 }).ok' 2>/dev/null | grep -qx "1"; then
      break
    fi
    sleep 1
  done
  demo_fail_if_exited "${name}"
  if ! docker exec "${name}" mongosh --quiet --eval 'db.runCommand({ ping: 1 }).ok' 2>/dev/null | grep -qx "1"; then
    echo "${name} の起動待ちがタイムアウトしました。" >&2
    docker logs "${name}" >&2 || true
    exit 1
  fi
  echo "  ${name} は起動済み"
done

echo "Phase 1 完了（コンテナは起動済み、Replica Set は未初期化）。"
