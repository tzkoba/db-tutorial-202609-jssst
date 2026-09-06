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
  echo "Container ${PG_CONTAINER} is not running. Run 01-start-instance.sh first."
  exit 1
fi

echo "Inserting committed row..."
demo_psql "${PG_CONTAINER}" "INSERT INTO demo_items (name) VALUES ('committed_before_crash');"

echo "Starting uncommitted transaction in background..."
echo
echo "# ${PG_CONTAINER}"
demo_print_sql "BEGIN; INSERT INTO demo_items (name) VALUES ('uncommitted_before_crash'); SELECT pg_sleep(120);"
docker exec -i "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -d postgres -v ON_ERROR_STOP=1 \
  -c "BEGIN; INSERT INTO demo_items (name) VALUES ('uncommitted_before_crash'); SELECT pg_sleep(120);" &
sleep 2

echo "Simulating crash (SIGKILL)..."
demo_run docker kill -s KILL "${PG_CONTAINER}"
wait || true

echo "Restarting ${PG_CONTAINER}..."
demo_run docker start "${PG_CONTAINER}"
wait_for_postgres "${PG_CONTAINER}"

echo "Recent log lines (recovery):"
demo_cmd docker logs "${PG_CONTAINER}"
docker logs "${PG_CONTAINER}" 2>&1 | tail -20

echo "Rows related to crash demo:"
demo_psql "${PG_CONTAINER}" "SELECT * FROM demo_items WHERE name LIKE '%crash%' ORDER BY id;"

if docker exec "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc \
  "SELECT count(*) FROM demo_items WHERE name = 'uncommitted_before_crash';" | grep -qx "0"; then
  echo "Uncommitted row absent as expected."
else
  echo "Expected uncommitted row to be missing."
  exit 1
fi

if ! docker exec "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc \
  "SELECT count(*) FROM demo_items WHERE name = 'committed_before_crash';" | grep -qx "1"; then
  echo "Expected committed row to survive crash recovery."
  exit 1
fi

echo "Phase 3 complete."
