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

if docker ps -a --format '{{.Names}}' | grep -qx "${PG_STANDBY}"; then
  echo "Standby container ${PG_STANDBY} already exists. Run cleanup.sh first."
  exit 1
fi

echo "Running pg_basebackup into volume ${PG_STANDBY_VOLUME}..."
# Bypass the image entrypoint (it only gosu's for CMD postgres). pg_basebackup
# then runs as root and creates $PG_VOLUME_MOUNT/18 as mode 0700, so the later
# postgres uid cannot mkdir/traverse it. chown the whole mount afterwards.
demo_run docker run --rm --network "${PG_NETWORK}" \
  -e PGPASSWORD="${PG_REPL_PASSWORD}" \
  -e PGHOST="${PG_PRIMARY}" \
  -e PGUSER="${PG_REPL_USER}" \
  -e PGDATADIR="${PG_DATA_DIR}" \
  -e PGVOL="${PG_VOLUME_MOUNT}" \
  -e PGSLOT="${PG_REPL_SLOT}" \
  -v "${PG_STANDBY_VOLUME}:${PG_VOLUME_MOUNT}" \
  --entrypoint bash \
  "${PG_IMAGE}" \
  -c 'set -euo pipefail
      pg_basebackup \
        -h "$PGHOST" -p 5432 -U "$PGUSER" \
        -D "$PGDATADIR" \
        -Fp -Xs -P -R \
        -S "$PGSLOT"
      chown -R postgres:postgres "$PGVOL"
      chmod 0755 "$PGVOL" "$PGVOL/18"
      chmod 0700 "$PGDATADIR"'

echo "Verifying standby.signal and primary_conninfo were created..."
docker run --rm \
  -e PGDATADIR="${PG_DATA_DIR}" \
  -v "${PG_STANDBY_VOLUME}:${PG_VOLUME_MOUNT}" \
  --entrypoint bash \
  "${PG_IMAGE}" \
  -c 'test -f "$PGDATADIR/standby.signal" && grep -q primary_conninfo "$PGDATADIR/postgresql.auto.conf"'

echo "Phase 3 complete."
