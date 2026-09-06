#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "Container ${PG_CONTAINER} is not running."
  exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/.recovery_target_time" ]]; then
  echo "Recovery target time not found. Run 05-basebackup.sh first."
  exit 1
fi

RECOVERY_TARGET="$(tr -d '\r\n' < "${SCRIPT_DIR}/.recovery_target_time")"
PGDATA_PARENT="$(dirname "${PG_DATA_DIR}")"

echo "Simulating mistaken DELETE..."
demo_psql "${PG_CONTAINER}" "DELETE FROM demo_items WHERE name LIKE 'before_mistake_%';"

echo "Rows after mistake (should be gone on primary):"
demo_psql "${PG_CONTAINER}" "SELECT * FROM demo_items WHERE name LIKE 'before_mistake_%';"

demo_psql "${PG_CONTAINER}" "SELECT pg_switch_wal();"

if docker ps -a --format '{{.Names}}' | grep -qx "${PG_PITR_CONTAINER}"; then
  docker rm -f "${PG_PITR_CONTAINER}" >/dev/null
fi

echo "Preparing PITR data directory from base backup..."
demo_run docker run --rm \
  -e PGVOL="${PG_VOLUME_MOUNT}" \
  -e PGDATADIR="${PG_DATA_DIR}" \
  -v "${PG_BACKUP_VOLUME}:/backup:ro" \
  -v "${PG_PITR_DATA_VOLUME}:${PG_VOLUME_MOUNT}" \
  --entrypoint bash \
  "${PG_IMAGE}" \
  -c 'set -euo pipefail
      rm -rf "${PGVOL:?}/"*
      mkdir -p "$PGDATADIR"
      cp -a /backup/. "$PGDATADIR/"
      chown -R postgres:postgres "$PGVOL"
      chmod 0755 "$PGVOL" "$(dirname "$PGDATADIR")"
      chmod 0700 "$PGDATADIR"'

echo "Configuring PITR recovery (target: ${RECOVERY_TARGET})..."
demo_run docker run --rm \
  -v "${PG_PITR_DATA_VOLUME}:${PG_VOLUME_MOUNT}" \
  --entrypoint bash \
  "${PG_IMAGE}" \
  -c "touch ${PG_DATA_DIR}/recovery.signal && cat >> ${PG_DATA_DIR}/postgresql.auto.conf <<EOF
restore_command = 'cp /archive/%f %p'
recovery_target_time = '${RECOVERY_TARGET}'
recovery_target_action = 'promote'
EOF
chown -R postgres:postgres ${PG_VOLUME_MOUNT}
chmod 0755 ${PG_VOLUME_MOUNT} ${PGDATA_PARENT}
chmod 0700 ${PG_DATA_DIR}"

echo "Starting PITR restore container ${PG_PITR_CONTAINER} on port ${PG_PITR_PORT}..."
demo_run docker run -d --name "${PG_PITR_CONTAINER}" \
  -p "${PG_PITR_PORT}:5432" \
  -v "${PG_PITR_DATA_VOLUME}:${PG_VOLUME_MOUNT}" \
  -v "${PG_ARCHIVE_VOLUME}:/archive:ro" \
  "${PG_IMAGE}"

echo "Waiting for PITR instance to accept connections..."
wait_for_postgres "${PG_PITR_CONTAINER}" 90

echo "Waiting for recovery_target_time and promote..."
promoted=0
for _ in $(seq 1 90); do
  if ! docker ps --format '{{.Names}}' | grep -qx "${PG_PITR_CONTAINER}"; then
    echo "PITR container exited. Logs:" >&2
    docker logs "${PG_PITR_CONTAINER}" >&2 || true
    exit 1
  fi
  if docker exec "${PG_PITR_CONTAINER}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc \
    "SELECT pg_is_in_recovery();" 2>/dev/null | grep -qx "f"; then
    promoted=1
    break
  fi
  sleep 1
done
if [[ "${promoted}" -ne 1 ]]; then
  echo "Timed out waiting for PITR promote. Logs:" >&2
  docker logs "${PG_PITR_CONTAINER}" >&2 || true
  exit 1
fi

echo "Rows restored on PITR instance:"
demo_psql "${PG_PITR_CONTAINER}" "SELECT * FROM demo_items WHERE name LIKE 'before_mistake_%' ORDER BY id;"

if ! docker exec "${PG_PITR_CONTAINER}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc \
  "SELECT count(*) FROM demo_items WHERE name LIKE 'before_mistake_%';" | grep -qx "2"; then
  echo "Expected two restored rows on PITR instance."
  exit 1
fi

echo "Phase 6 complete."
