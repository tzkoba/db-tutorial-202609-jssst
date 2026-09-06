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
    echo "Container ${name} already exists. Run cleanup.sh first."
    exit 1
  fi
done

echo "Starting ${MONGO1} on host port ${MONGO1_PORT}..."
demo_run docker run -d --name "${MONGO1}" --hostname "${MONGO1}" --network "${MONGO_NETWORK}" \
  -p "${MONGO1_PORT}:27017" \
  "${MONGO_IMAGE}" mongod --replSet "${MONGO_RS}" --bind_ip_all

echo "Starting ${MONGO2} on host port ${MONGO2_PORT}..."
demo_run docker run -d --name "${MONGO2}" --hostname "${MONGO2}" --network "${MONGO_NETWORK}" \
  -p "${MONGO2_PORT}:27017" \
  "${MONGO_IMAGE}" mongod --replSet "${MONGO_RS}" --bind_ip_all

echo "Starting ${MONGO3} on host port ${MONGO3_PORT}..."
demo_run docker run -d --name "${MONGO3}" --hostname "${MONGO3}" --network "${MONGO_NETWORK}" \
  -p "${MONGO3_PORT}:27017" \
  "${MONGO_IMAGE}" mongod --replSet "${MONGO_RS}" --bind_ip_all

echo "Waiting for mongod to accept connections..."
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
    echo "Timed out waiting for ${name}." >&2
    docker logs "${name}" >&2 || true
    exit 1
  fi
  echo "  ${name} is up"
done

echo "Phase 1 complete (containers up; Replica Set not initialized yet)."
