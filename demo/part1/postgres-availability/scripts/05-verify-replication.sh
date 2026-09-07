#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_PRIMARY}"; then
  echo "Primary container ${PG_PRIMARY} is not running."
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_STANDBY}"; then
  echo "Standby container ${PG_STANDBY} is not running. Run 04-start-standby.sh first."
  exit 1
fi

sync_state="$(docker exec "${PG_PRIMARY}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc \
  "SELECT COALESCE(sync_state, '') FROM pg_stat_replication LIMIT 1;" | tr -d '\r')"
if [[ "${sync_state}" != "sync" ]]; then
  echo "Standby is not synchronous (sync_state='${sync_state}'). Run 04b-enable-sync.sh first."
  exit 1
fi

echo "Primary sync settings:"
demo_psql "${PG_PRIMARY}" <<'SQL'
SHOW synchronous_commit;
SHOW synchronous_standby_names;
SELECT pid, application_name, state, sync_state FROM pg_stat_replication;
SQL

echo "Inserting row on primary..."
demo_psql "${PG_PRIMARY}" "INSERT INTO demo_items (name) VALUES ('after_replication');"

echo "Reading rows on standby..."
demo_psql "${PG_STANDBY}" "SELECT * FROM demo_items ORDER BY id;"

echo "Checking standby rejects writes..."
if demo_psql_allow_fail "${PG_STANDBY}" "INSERT INTO demo_items (name) VALUES ('should_fail');"; then
  echo "Expected standby write to fail, but it succeeded."
  exit 1
fi
echo "Standby write rejected as expected."

echo "Optional lag check:"
demo_psql "${PG_PRIMARY}" "SELECT pg_current_wal_lsn();"
demo_psql "${PG_STANDBY}" "SELECT pg_last_wal_replay_lsn();"

echo "Phase 5 complete."
