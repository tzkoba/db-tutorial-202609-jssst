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

echo "Configuring primary for streaming replication..."
demo_psql "${PG_PRIMARY}" <<'SQL'
ALTER SYSTEM SET listen_addresses TO '*';
ALTER SYSTEM SET wal_level TO 'replica';
ALTER SYSTEM SET max_wal_senders TO 10;
ALTER SYSTEM SET max_replication_slots TO 10;
ALTER SYSTEM SET hot_standby TO on;
SQL

echo "Restarting primary to apply wal_level and listen_addresses..."
demo_run docker restart "${PG_PRIMARY}"
until docker exec "${PG_PRIMARY}" pg_isready -U "${PG_SUPERUSER}" >/dev/null 2>&1; do
  sleep 1
done

echo "Creating replication user..."
demo_psql "${PG_PRIMARY}" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PG_REPL_USER}') THEN
    EXECUTE format('CREATE USER %I WITH REPLICATION PASSWORD %L LOGIN', '${PG_REPL_USER}', '${PG_REPL_PASSWORD}');
  END IF;
END
\$\$;
SQL

echo "Updating pg_hba.conf..."
demo_run docker exec "${PG_PRIMARY}" bash -c "grep -q 'replication ${PG_REPL_USER}' '${PG_DATA_DIR}/pg_hba.conf' || echo 'host replication ${PG_REPL_USER} 172.16.0.0/12 scram-sha-256' >> '${PG_DATA_DIR}/pg_hba.conf'"

echo "Restarting primary to apply pg_hba.conf..."
demo_run docker restart "${PG_PRIMARY}"
until docker exec "${PG_PRIMARY}" pg_isready -U "${PG_SUPERUSER}" >/dev/null 2>&1; do
  sleep 1
done

echo "Creating replication slot ${PG_REPL_SLOT}..."
demo_psql "${PG_PRIMARY}" <<SQL
SELECT pg_create_physical_replication_slot('${PG_REPL_SLOT}')
WHERE NOT EXISTS (
  SELECT 1 FROM pg_replication_slots WHERE slot_name = '${PG_REPL_SLOT}'
);
SQL

demo_psql "${PG_PRIMARY}" "SHOW wal_level;"
demo_psql "${PG_PRIMARY}" "SELECT slot_name, slot_type, active FROM pg_replication_slots;"

echo "Phase 2 complete."
