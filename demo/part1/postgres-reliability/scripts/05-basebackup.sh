#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "Container ${PG_CONTAINER} is not running."
  exit 1
fi

echo "Taking base backup into /backup..."
docker exec "${PG_CONTAINER}" bash -c \
  'chown postgres:postgres /backup && rm -rf /backup/*'
demo_run docker exec -u postgres "${PG_CONTAINER}" pg_basebackup \
  -U "${PG_SUPERUSER}" -D /backup -Fp -Xs -P

echo "Inserting rows before simulated mistake..."
demo_psql "${PG_CONTAINER}" "INSERT INTO demo_items (name) VALUES ('before_mistake_1');"
sleep 2
demo_psql "${PG_CONTAINER}" "INSERT INTO demo_items (name) VALUES ('before_mistake_2');"

echo "Recording recovery target time:"
demo_psql "${PG_CONTAINER}" "SELECT clock_timestamp();"
RECOVERY_TARGET="$(docker exec "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc \
  "SELECT clock_timestamp();")"
echo "${RECOVERY_TARGET}" > "${SCRIPT_DIR}/.recovery_target_time"

demo_psql "${PG_CONTAINER}" "SELECT pg_switch_wal();"

echo "Phase 5 complete."
