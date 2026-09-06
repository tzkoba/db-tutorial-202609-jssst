#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../demo-lib.sh
source "${SCRIPT_DIR}/../../demo-lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx "${PG_STANDBY}"; then
  echo "Standby container ${PG_STANDBY} is not running. Run 04-start-standby.sh first."
  exit 1
fi

if docker ps --format '{{.Names}}' | grep -qx "${PG_PRIMARY}"; then
  echo "Stopping primary ${PG_PRIMARY}..."
  demo_run docker stop "${PG_PRIMARY}"
fi

echo "Promoting standby..."
demo_psql "${PG_STANDBY}" "SELECT pg_promote();"

echo "Waiting for promotion to complete..."
until docker exec "${PG_STANDBY}" psql -U "${PG_SUPERUSER}" -d postgres -Atqc "SELECT pg_is_in_recovery();" | grep -qx "f"; do
  sleep 1
done

echo "Inserting row on promoted standby..."
demo_psql "${PG_STANDBY}" <<'SQL'
INSERT INTO demo_items (name) VALUES ('after_failover');
SELECT * FROM demo_items ORDER BY id;
SQL

echo "Phase 6 complete."
