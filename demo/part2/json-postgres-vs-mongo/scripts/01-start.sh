#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

"${SCRIPT_DIR}/00-preflight.sh"

section "Phase 1: Start PostgreSQL + MongoDB (single node each)"

for name in "${PG_CONTAINER}" "${MONGO_CONTAINER}"; do
  if docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
    echo "Container ${name} already exists. Run cleanup.sh first." >&2
    exit 1
  fi
done

echo "Starting ${PG_CONTAINER} (postgres:18, host port ${PG_PORT})..."
demo_run docker run -d --name "${PG_CONTAINER}" --network "${DEMO_NETWORK}" \
  -e POSTGRES_PASSWORD="${PG_PASSWORD}" \
  -e POSTGRES_DB="${PG_DB}" \
  -p "${PG_PORT}:5432" \
  "${PG_IMAGE}"

echo "Starting ${MONGO_CONTAINER} (mongo:8, host port ${MONGO_PORT})..."
demo_run docker run -d --name "${MONGO_CONTAINER}" --network "${DEMO_NETWORK}" \
  -p "${MONGO_PORT}:27017" \
  "${MONGO_IMAGE}"

echo "Waiting for PostgreSQL..."
for _ in $(seq 1 60); do
  demo_fail_if_exited "${PG_CONTAINER}"
  if docker exec "${PG_CONTAINER}" pg_isready -U "${PG_USER}" -d "${PG_DB}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
demo_fail_if_exited "${PG_CONTAINER}"
if ! docker exec "${PG_CONTAINER}" pg_isready -U "${PG_USER}" -d "${PG_DB}" >/dev/null 2>&1; then
  echo "Timed out waiting for ${PG_CONTAINER}." >&2
  docker logs "${PG_CONTAINER}" >&2 || true
  exit 1
fi

echo "Waiting for MongoDB..."
for _ in $(seq 1 60); do
  demo_fail_if_exited "${MONGO_CONTAINER}"
  if docker exec "${MONGO_CONTAINER}" mongosh --quiet --eval 'db.runCommand({ ping: 1 }).ok' 2>/dev/null | grep -q 1; then
    break
  fi
  sleep 1
done
demo_fail_if_exited "${MONGO_CONTAINER}"
if ! docker exec "${MONGO_CONTAINER}" mongosh --quiet --eval 'db.runCommand({ ping: 1 }).ok' 2>/dev/null | grep -q 1; then
  echo "Timed out waiting for ${MONGO_CONTAINER}." >&2
  docker logs "${MONGO_CONTAINER}" >&2 || true
  exit 1
fi

copy_sample_into_containers

echo "Phase 1 complete."
echo "  PostgreSQL: localhost:${PG_PORT}  db=${PG_DB}"
echo "  MongoDB:    localhost:${MONGO_PORT} db=${MONGO_DB}"
