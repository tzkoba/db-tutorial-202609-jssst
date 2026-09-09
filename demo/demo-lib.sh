# Shared lecture-demo output helpers.
# Source after each demo's common.env.

demo_pg_user() {
  echo "${PG_USER:-${PG_SUPERUSER:-postgres}}"
}

demo_pg_db() {
  echo "${PG_DB:-postgres}"
}

demo_pg_password() {
  echo "${PG_PASSWORD:-${PG_SUPERUSER_PASSWORD:-postgres}}"
}

demo_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Print an expanded shell-style command line.
demo_cmd() {
  echo
  echo "\$ $*"
}

# Print the command, then run it.
demo_run() {
  demo_cmd "$@"
  "$@"
}

demo_fail_if_exited() {
  local name="$1"
  if ! docker ps --format '{{.Names}}' | grep -qx "${name}"; then
    echo "コンテナ ${name} が動いていません。ログ:" >&2
    docker logs "${name}" >&2 || true
    return 1
  fi
  return 0
}

# Print SQL in a psql-like prompt (${db}=# / ${db}-# ).
# Optional 2nd arg overrides the database name (Part3: yugabyte).
demo_print_sql() {
  local sql="$1"
  local db="${2:-}"
  if [[ -z "${db}" ]]; then
    db="$(demo_pg_db)"
  fi
  local first=1
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${first}" -eq 1 && -z "${line}" ]]; then
      continue
    fi
    if [[ "${first}" -eq 1 ]]; then
      printf '%s=# %s\n' "${db}" "${line}"
      first=0
    else
      printf '%s-# %s\n' "${db}" "${line}"
    fi
  done <<< "${sql}"
}

# Print JS in a mongosh-like prompt (${db}> / ... ).
demo_print_js() {
  local prompt_db="$1"
  local js="$2"
  local first=1
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${first}" -eq 1 && -z "${line}" ]]; then
      continue
    fi
    if [[ "${first}" -eq 1 ]]; then
      printf '%s> %s\n' "${prompt_db}" "${line}"
      first=0
    else
      printf '... %s\n' "${line}"
    fi
  done <<< "${js}"
}

# demo_psql CONTAINER [SQL]
# If SQL is omitted, read it from stdin (heredoc).
demo_psql() {
  local container="$1"
  local sql="${2:-}"
  local user db password
  if [[ -z "${sql}" ]]; then
    sql="$(cat)"
  fi
  sql="$(demo_trim "${sql}")"
  user="$(demo_pg_user)"
  db="$(demo_pg_db)"
  password="$(demo_pg_password)"
  echo
  echo "# ${container}"
  demo_print_sql "${sql}"
  # stdin, not -c: psql -c wraps multiple statements in one transaction,
  # and ALTER SYSTEM cannot run inside a transactional block.
  printf '%s\n' "${sql}" | docker exec -i -e PGPASSWORD="${password}" "${container}" \
    psql -U "${user}" -d "${db}" -v ON_ERROR_STOP=1
}

# Same display as demo_psql, but do not stop on SQL error (for expected failures).
demo_psql_allow_fail() {
  local container="$1"
  local sql="${2:-}"
  local user db password status
  if [[ -z "${sql}" ]]; then
    sql="$(cat)"
  fi
  sql="$(demo_trim "${sql}")"
  user="$(demo_pg_user)"
  db="$(demo_pg_db)"
  password="$(demo_pg_password)"
  echo
  echo "# ${container}"
  demo_print_sql "${sql}"
  status=0
  printf '%s\n' "${sql}" | docker exec -i -e PGPASSWORD="${password}" "${container}" \
    psql -U "${user}" -d "${db}" || status=$?
  return "${status}"
}

# demo_ysql CONTAINER [SQL]
# If SQL is omitted, read it from stdin (heredoc).
# Connects with -h CONTAINER (YSQL advertises the container hostname, not localhost).
# stdin, not -c: same multi-statement rule as demo_psql.
demo_ysql() {
  local container="$1"
  local sql="${2:-}"
  local user db
  if [[ -z "${sql}" ]]; then
    sql="$(cat)"
  fi
  sql="$(demo_trim "${sql}")"
  user="${YB_USER:-yugabyte}"
  db="${YB_DB:-yugabyte}"
  echo
  echo "# ${container}"
  demo_print_sql "${sql}" "${db}"
  printf '%s\n' "${sql}" | docker exec -i "${container}" \
    bin/ysqlsh -h "${container}" -U "${user}" -d "${db}" -v ON_ERROR_STOP=1
}

# Same display as demo_ysql, but do not stop on SQL error (for expected failures).
demo_ysql_allow_fail() {
  local container="$1"
  local sql="${2:-}"
  local user db status
  if [[ -z "${sql}" ]]; then
    sql="$(cat)"
  fi
  sql="$(demo_trim "${sql}")"
  user="${YB_USER:-yugabyte}"
  db="${YB_DB:-yugabyte}"
  echo
  echo "# ${container}"
  demo_print_sql "${sql}" "${db}"
  status=0
  printf '%s\n' "${sql}" | docker exec -i "${container}" \
    bin/ysqlsh -h "${container}" -U "${user}" -d "${db}" || status=$?
  return "${status}"
}

# Run JS in mongosh with the same async rewriter as --eval / interactive
# (so rs.status(), insertOne, find, countDocuments await properly).
#
# The script is written on the host and docker-cp'd into the container, then
# loaded with --file. Do not:
#   - put user JS on docker exec / mongosh --eval argv (quotes around
#     ObjectId('hex') get dropped; hex then parses as number+identifier)
#   - pipe JS through `docker exec -i ... sh -c 'cat >file'` (Rancher/WSL
#     stdin often never reaches cat, so the same quoting bug survives)
#   - wrap the script in JS eval() (skips mongosh's rewriter; rs.status()
#     is undefined and `.members.map` throws)
#
# ObjectId lookups must not go through this helper with hex baked into JS.
# Use demo_mongosh_count_by_oid (static --file script + JSON params).
#
# Callers (keep this list current when changing this helper):
#   demo/part2/mongo-availability-consistency/scripts/{02,03,03b,06}*.sh
#   demo/part2/mongo-availability-consistency/scripts/lib.sh
#     (sample insertOne only; _id scans use demo_mongosh_count_by_oid)
#   demo/part2/json-postgres-vs-mongo/scripts/lib.sh mongo_eval
#     (02-insert drop + phases 2–5)
demo_mongosh_exec() {
  local container="$1"
  local js="$2"
  local prompt_db="${3:-${MONGO_DB:-test}}"
  local tmp
  js="$(demo_trim "${js}")"
  tmp="$(mktemp)"
  printf '%s\n' "db = db.getSiblingDB('${prompt_db}'); ${js}" > "${tmp}"
  docker cp "${tmp}" "${container}:/tmp/demo-eval.js" >/dev/null
  rm -f "${tmp}"
  docker exec -u 0 "${container}" chmod a+r /tmp/demo-eval.js
  docker exec "${container}" mongosh --quiet --file /tmp/demo-eval.js
}

# Look up one _id without generating mongosh JS.
#
# Encoding the hex into --eval (quotes, process.env, Uint8Array, IIFE-to-hex)
# keeps hitting mongosh's async rewriter and bson's ObjectId checks. The id
# is JSON data; a committed script is docker-cp'd and run with --file.
demo_mongosh_count_by_oid() {
  local container="$1"
  local oid="$2"
  local db_name="${3:-${MONGO_DB:-test}}"
  local coll="${4:-${MONGO_COLL:-writes}}"
  local read_concern="${5:-}"
  local lib_dir params
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ ! "${oid}" =~ ^[0-9a-fA-F]{24}$ ]]; then
    echo "24 文字 hex の ObjectId ではありません: ${oid}" >&2
    return 1
  fi
  if [[ ! "${db_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ || ! "${coll}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "db/coll は識別子である必要があります: ${db_name}.${coll}" >&2
    return 1
  fi
  if [[ -n "${read_concern}" && ! "${read_concern}" =~ ^(local|majority|available|linearizable)$ ]]; then
    echo "未対応の readConcern: ${read_concern}" >&2
    return 1
  fi
  params="$(mktemp)"
  if [[ -n "${read_concern}" ]]; then
    printf '{"db":"%s","coll":"%s","oid":"%s","readConcern":"%s"}\n' \
      "${db_name}" "${coll}" "${oid}" "${read_concern}" > "${params}"
  else
    printf '{"db":"%s","coll":"%s","oid":"%s"}\n' "${db_name}" "${coll}" "${oid}" > "${params}"
  fi
  docker cp "${lib_dir}/mongosh-count-by-oid.js" "${container}:/tmp/demo-count-by-oid.js" >/dev/null
  docker cp "${params}" "${container}:/tmp/demo-count-params.json" >/dev/null
  rm -f "${params}"
  docker exec -u 0 "${container}" chmod a+r /tmp/demo-count-by-oid.js /tmp/demo-count-params.json
  docker exec "${container}" mongosh --quiet --file /tmp/demo-count-by-oid.js
}

# One find({_id: {$in: [...]}}) for every acked hex in SUCCESS_FILE.
# Prints FOUND / MISSING / SAMPLE_* / LOST lines (see mongosh-scan-acked-ids.js).
demo_mongosh_scan_acked_ids() {
  local container="$1"
  local success_file="$2"
  local db_name="${3:-${MONGO_DB:-test}}"
  local coll="${4:-${MONGO_COLL:-writes}}"
  local read_concern="${5:-}"
  local lib_dir params oids_json first hex
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ ! "${db_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ || ! "${coll}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "db/coll は識別子である必要があります: ${db_name}.${coll}" >&2
    return 1
  fi
  if [[ -n "${read_concern}" && ! "${read_concern}" =~ ^(local|majority|available|linearizable)$ ]]; then
    echo "未対応の readConcern: ${read_concern}" >&2
    return 1
  fi
  oids_json="["
  first=1
  while IFS= read -r hex || [[ -n "${hex}" ]]; do
    hex="${hex//$'\r'/}"
    [[ "${hex}" =~ ^[0-9a-fA-F]{24}$ ]] || continue
    if [[ "${first}" -eq 1 ]]; then
      first=0
    else
      oids_json+=","
    fi
    oids_json+="\"${hex}\""
  done < "${success_file}"
  oids_json+="]"
  params="$(mktemp)"
  if [[ -n "${read_concern}" ]]; then
    printf '{"db":"%s","coll":"%s","oids":%s,"readConcern":"%s"}\n' \
      "${db_name}" "${coll}" "${oids_json}" "${read_concern}" > "${params}"
  else
    printf '{"db":"%s","coll":"%s","oids":%s}\n' "${db_name}" "${coll}" "${oids_json}" > "${params}"
  fi
  docker cp "${lib_dir}/mongosh-scan-acked-ids.js" "${container}:/tmp/demo-scan-acked-ids.js" >/dev/null
  docker cp "${params}" "${container}:/tmp/demo-scan-acked.json" >/dev/null
  rm -f "${params}"
  docker exec -u 0 "${container}" chmod a+r /tmp/demo-scan-acked-ids.js /tmp/demo-scan-acked.json
  docker exec "${container}" mongosh --quiet --file /tmp/demo-scan-acked-ids.js
}

# demo_mongosh CONTAINER JS [prompt_db]
# prompt_db defaults to MONGO_DB (or test).
demo_mongosh() {
  local container="$1"
  local js="${2:-}"
  local prompt_db="${3:-${MONGO_DB:-test}}"
  if [[ -z "${js}" ]]; then
    js="$(cat)"
  fi
  js="$(demo_trim "${js}")"
  echo
  echo "# ${container}"
  demo_print_js "${prompt_db}" "${js}"
  demo_mongosh_exec "${container}" "${js}" "${prompt_db}"
}
