#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_PRIMARY}"; then
  echo "Primary container ${PG_PRIMARY} is not running. Run 01-start-primary.sh first."
  exit 1
fi
if ! docker ps --format '{{.Names}}' | grep -qx "${PG_STANDBY}"; then
  echo "Standby container ${PG_STANDBY} is not running. Run 04-start-standby.sh first."
  exit 1
fi

echo "Enabling synchronous replication on primary only (standby WAL flush)..."
demo_psql "${PG_PRIMARY}" <<'SQL'
ALTER SYSTEM SET synchronous_commit TO 'on';
ALTER SYSTEM SET synchronous_standby_names TO '*';
SELECT pg_reload_conf();
SQL

echo "Waiting until pg_stat_replication.sync_state = sync..."
sync_state=""
for _ in $(seq 1 30); do
  sync_state="$(docker exec "${PG_PRIMARY}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc \
    "SELECT COALESCE(sync_state, '') FROM pg_stat_replication LIMIT 1;" | tr -d '\r')"
  if [[ "${sync_state}" == "sync" ]]; then
    break
  fi
  sleep 1
done
if [[ "${sync_state}" != "sync" ]]; then
  echo "Timed out waiting for synchronous standby (sync_state='${sync_state}')." >&2
  demo_psql "${PG_PRIMARY}" "SELECT pid, application_name, state, sync_state FROM pg_stat_replication;"
  exit 1
fi

demo_psql "${PG_PRIMARY}" <<'SQL'
SHOW synchronous_commit;
SHOW synchronous_standby_names;
SELECT pid, usename, application_name, state, sync_state
FROM pg_stat_replication;
SQL

echo "Phase 4.5 complete (primary is synchronous; standby config unchanged)."
