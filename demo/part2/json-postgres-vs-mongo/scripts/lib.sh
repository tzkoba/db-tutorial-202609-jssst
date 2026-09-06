#!/usr/bin/env bash
# Helpers for json-postgres-vs-mongo demos. Source after common.env.

# shellcheck source=../../../demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../demo-lib.sh"

section() {
  echo
  echo "============================================================"
  echo "$*"
  echo "============================================================"
}

subsection() {
  echo
  echo "----- $* -----"
}

pg_psql() {
  demo_psql "${PG_CONTAINER}" "$@"
}

pg_sql() {
  demo_psql "${PG_CONTAINER}" "$1"
}

mongo_eval() {
  demo_mongosh "${MONGO_CONTAINER}" "$1" "${MONGO_DB}"
}

require_containers() {
  local name
  for name in "${PG_CONTAINER}" "${MONGO_CONTAINER}"; do
    if ! docker ps --format '{{.Names}}' | grep -qx "${name}"; then
      echo "Container ${name} is not running. Run 01-start.sh first." >&2
      exit 1
    fi
  done
}

copy_sample_into_containers() {
  docker cp "${DATA_FILE}" "${PG_CONTAINER}:/tmp/sample-orders.json"
  docker cp "${DATA_FILE}" "${MONGO_CONTAINER}:/tmp/sample-orders.json"
}

# Load sample JSON array into PostgreSQL orders.doc via dollar-quoting from the host file.
# Show a short SQL skeleton; do not dump the whole JSON file into the lecture transcript.
pg_load_sample_orders() {
  local user db password
  user="$(demo_pg_user)"
  db="$(demo_pg_db)"
  password="$(demo_pg_password)"
  echo
  echo "# ${PG_CONTAINER}"
  demo_print_sql "INSERT INTO orders (doc)
SELECT value
FROM jsonb_array_elements(<${DATA_FILE}>::jsonb);"
  docker exec -i -e PGPASSWORD="${password}" "${PG_CONTAINER}" \
    psql -U "${user}" -d "${db}" -v ON_ERROR_STOP=1 <<SQL
INSERT INTO orders (doc)
SELECT value
FROM jsonb_array_elements(\$json\$$(cat "${DATA_FILE}")\$json\$::jsonb);
SQL
}
