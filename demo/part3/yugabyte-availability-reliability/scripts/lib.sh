#!/usr/bin/env bash
# Helpers for YugabyteDB demo scripts. Source after common.env.

# shellcheck source=../../../demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../demo-lib.sh"

yb_nodes() {
  echo "${YB1}" "${YB2}" "${YB3}"
}

first_running_node() {
  local node
  for node in $(yb_nodes); do
    if docker ps --format '{{.Names}}' | grep -qx "${node}"; then
      echo "${node}"
      return 0
    fi
  done
  return 1
}

master_addresses() {
  local addrs=() node
  for node in $(yb_nodes); do
    if docker ps --format '{{.Names}}' | grep -qx "${node}"; then
      addrs+=("${node}:7100")
    fi
  done
  local IFS=,
  echo "${addrs[*]}"
}

ysql() {
  # Usage: ysql <container> [ysqlsh args...]
  local node="$1"
  shift
  docker exec -i "${node}" bin/ysqlsh -h "${node}" -U "${YB_USER}" -d "${YB_DB}" -v ON_ERROR_STOP=1 "$@"
}

ysql_q() {
  # Quiet single-statement query; prints result rows only.
  local node="$1"
  local sql="$2"
  docker exec "${node}" bin/ysqlsh -h "${node}" -U "${YB_USER}" -d "${YB_DB}" -v ON_ERROR_STOP=1 -t -A -c "${sql}" 2>/dev/null | tr -d '\r' | sed '/^$/d'
}

wait_for_ysql() {
  local node="$1"
  local i
  for i in $(seq 1 180); do
    demo_fail_if_exited "${node}" || return 1
    if docker exec "${node}" bin/ysqlsh -h "${node}" -U "${YB_USER}" -d "${YB_DB}" -c 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for YSQL on ${node}" >&2
  return 1
}

wait_for_cluster_ready() {
  local node i count n
  node="$(first_running_node)" || return 1
  for i in $(seq 1 90); do
    for n in $(yb_nodes); do
      demo_fail_if_exited "${n}" || return 1
    done
    count="$(ysql_q "${node}" "SELECT count(*) FROM yb_servers();" || true)"
    if [[ "${count}" == "3" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for 3 servers in yb_servers()" >&2
  return 1
}

# Lecture transcript: one committed id lookup (full scan stays hidden).
show_one_id_check() {
  local container="$1"
  local id="$2"
  if [[ ! "${id}" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  demo_ysql "${container}" "SELECT count(*) FROM ${YB_TABLE} WHERE id = ${id};"
}

yb_admin() {
  local node
  node="$(first_running_node)" || return 1
  local masters
  masters="$(master_addresses)"
  docker exec "${node}" bash -lc "yb-admin --master_addresses=${masters} $*"
}

# Resolve a tablet Leader container for YB_TABLE (ysql.yugabyte.<table>).
# Picks the first tablet's Leader-IP from yb-admin list_tablets. Falls back to
# the first running node if parsing fails.
find_tablet_leader_container() {
  local table="${1:-${YB_TABLE}}"
  local node masters raw leader_host line cand leader_ip

  node="$(first_running_node)" || return 1
  masters="$(master_addresses)"

  raw="$(docker exec "${node}" bash -lc \
    "yb-admin --master_addresses=${masters} list_tablets ysql.${YB_DB} ${table} 2>/dev/null" || true)"

  # Preferred modern format: columns Tablet-UUID Range Leader-IP Leader-UUID
  leader_host="$(echo "${raw}" | awk 'NR>1 && $1 ~ /^[0-9a-f]/ {print $NF}' 2>/dev/null || true)"
  # If last field is UUID, Leader-IP is usually the field before last that looks like host:port
  line="$(echo "${raw}" | awk 'NR>1 && $1 ~ /^[0-9a-f]/ {print; exit}' || true)"
  if [[ -n "${line}" ]]; then
    leader_host="$(echo "${line}" | grep -oE '[A-Za-z0-9_.-]+:[0-9]+' | head -n1 | cut -d: -f1 || true)"
  fi

  if [[ -z "${leader_host}" ]]; then
    # Older "Leader: <uuid> (<host>:<port>)" style
    leader_host="$(echo "${raw}" | grep -oiE 'Leader:[[:space:]]*[0-9a-f-]+[[:space:]]*\([^)]+\)' | head -n1 \
      | sed -E 's/.*\(([^:]+):[0-9]+\).*/\1/' || true)"
  fi

  if [[ -n "${leader_host}" ]]; then
    for cand in $(yb_nodes); do
      if [[ "${leader_host}" == "${cand}" ]]; then
        echo "${cand}"
        return 0
      fi
      leader_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${cand}" 2>/dev/null || true)"
      if [[ -n "${leader_ip}" && "${leader_host}" == "${leader_ip}" ]]; then
        echo "${cand}"
        return 0
      fi
    done
  fi

  echo "${node}"
  return 0
}

assert_sql_ident() {
  local name="$1"
  if [[ ! "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "not a SQL identifier: ${name}" >&2
    return 1
  fi
}

# First tablet UUID from yb-admin list_tablets (user table, hash-split into 1 tablet).
find_tablet_id() {
  local table="${1:-${YB_TABLE}}"
  local node masters raw
  assert_sql_ident "${table}" || return 1
  node="$(first_running_node)" || return 1
  masters="$(master_addresses)"
  raw="$(docker exec "${node}" bash -lc \
    "yb-admin --master_addresses=${masters} list_tablets ysql.${YB_DB} ${table} 0 2>/dev/null" || true)"
  echo "${raw}" | awk 'NR>1 && $1 ~ /^[0-9a-fA-F]{16,}$/ { print $1; exit }'
}

count_named_table() {
  local node="$1"
  local table="$2"
  local where="${3:-true}"
  assert_sql_ident "${table}" || return 1
  ysql_q "${node}" "SELECT count(*) FROM ${table} WHERE ${where};"
}

# Lecture: each table has its own tablet (and Leader). Prefer yb_tablet_metadata
# when present; on 2024.2 fall back to yb_table_properties + per-node
# yb_local_tablets, then SELECT the resolved Leader mapping.
show_table_tablet_leaders() {
  local ep="$1"
  local t1="${2:-${YB_TXN_T1}}"
  local t2="${3:-${YB_TXN_T2}}"
  local node meta tid1 tid2 l1 l2
  assert_sql_ident "${t1}" && assert_sql_ident "${t2}" || return 1

  echo ""
  echo "--- Each table has its own tablet (not colocated) ---"
  demo_ysql "${ep}" "
SELECT c.relname AS table_name,
       (yb_table_properties(c.oid)).num_tablets,
       (yb_table_properties(c.oid)).is_colocated
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('${t1}', '${t2}')
ORDER BY c.relname;
"

  meta="$(ysql_q "${ep}" "SELECT count(*) FROM yb_tablet_metadata WHERE relname IN ('${t1}', '${t2}')" || true)"
  if [[ "${meta}" =~ ^[0-9]+$ ]]; then
    echo ""
    echo "--- Tablet Leaders (yb_tablet_metadata) ---"
    demo_ysql "${ep}" "
SELECT ytm.relname AS table_name,
       ytm.tablet_id,
       ytm.leader
FROM yb_tablet_metadata ytm
WHERE ytm.db_name = current_database()
  AND ytm.relname IN ('${t1}', '${t2}')
ORDER BY ytm.relname, ytm.tablet_id;
"
    return 0
  fi

  echo ""
  echo "--- Tablets on each node (yb_local_tablets; replicas of both tables) ---"
  for node in $(yb_nodes); do
    if ! docker ps --format '{{.Names}}' | grep -qx "${node}"; then
      continue
    fi
    demo_ysql "${node}" "
SELECT table_name, tablet_id
FROM yb_local_tablets
WHERE namespace_name = current_database()
  AND table_name IN ('${t1}', '${t2}')
ORDER BY table_name, tablet_id;
"
  done

  tid1="$(find_tablet_id "${t1}")"
  tid2="$(find_tablet_id "${t2}")"
  l1="$(find_tablet_leader_container "${t1}")"
  l2="$(find_tablet_leader_container "${t2}")"
  echo ""
  echo "--- Resolved tablet Leader per table ---"
  demo_ysql "${ep}" "
SELECT table_name, tablet_id, leader_node
FROM (VALUES
  ('${t1}', '${tid1}', '${l1}'),
  ('${t2}', '${tid2}', '${l2}')
) AS t(table_name, tablet_id, leader_node);
"
}

wait_for_writable_endpoint() {
  local i node
  for i in $(seq 1 45); do
    for node in $(yb_nodes); do
      if ! docker ps --format '{{.Names}}' | grep -qx "${node}"; then
        continue
      fi
      if timeout 12 docker exec "${node}" bin/ysqlsh -h "${node}" -U "${YB_USER}" -d "${YB_DB}" \
        -c "INSERT INTO ${YB_TABLE}(tag) VALUES ('probe') RETURNING id;" >/dev/null 2>&1; then
        timeout 12 docker exec "${node}" bin/ysqlsh -h "${node}" -U "${YB_USER}" -d "${YB_DB}" \
          -c "DELETE FROM ${YB_TABLE} WHERE tag = 'probe';" >/dev/null 2>&1 || true
        echo "${node}"
        return 0
      fi
    done
    sleep 2
  done
  echo "Timed out waiting for a writable YSQL endpoint" >&2
  return 1
}

count_rows() {
  local node="$1"
  local where="${2:-true}"
  ysql_q "${node}" "SELECT count(*) FROM ${YB_TABLE} WHERE ${where};"
}

quick_writable_node() {
  local node
  for node in $(yb_nodes); do
    if ! docker ps --format '{{.Names}}' | grep -qx "${node}"; then
      continue
    fi
    if timeout 8 docker exec "${node}" bin/ysqlsh -h "${node}" -U "${YB_USER}" -d "${YB_DB}" \
      -c "SELECT 1" >/dev/null 2>&1; then
      echo "${node}"
      return 0
    fi
  done
  return 1
}

run_insert_clients() {
  local success_file="$1"
  local client_count="${2:-3}"
  local duration_sec="${3:-25}"
  local tag_prefix="${4:-failover}"

  : > "${success_file}"
  mkdir -p "${RUN_DIR}/clients"

  local i
  for i in $(seq 1 "${client_count}"); do
    (
      local end=$((SECONDS + duration_sec))
      local n=0
      local endpoint id
      while (( SECONDS < end )); do
        endpoint="$(quick_writable_node 2>/dev/null || true)"
        if [[ -z "${endpoint}" ]]; then
          sleep 0.2
          continue
        fi
        id="$(docker exec "${endpoint}" bin/ysqlsh -h "${endpoint}" -U "${YB_USER}" -d "${YB_DB}" -t -A -c \
          "INSERT INTO ${YB_TABLE}(tag, client_id, n) VALUES ('${tag_prefix}', ${i}, ${n}) RETURNING id;" \
          2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' | tail -n 1 || true)"
        if [[ "${id}" =~ ^[0-9]+$ ]]; then
          echo "${id}" >> "${success_file}"
        fi
        n=$((n + 1))
        sleep 0.05
      done
    ) > "${RUN_DIR}/clients/client-${i}.log" 2>&1 &
  done

  echo "Started ${client_count} INSERT clients (tag=${tag_prefix}, duration=${duration_sec}s)"
}

wait_clients() {
  wait || true
}

available_mem_mb() {
  # Prefer MemAvailable from /proc/meminfo
  local kb
  kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
  if [[ -n "${kb}" ]]; then
    echo $((kb / 1024))
    return 0
  fi
  free -m | awk '/Mem:/ {print $7}'
}
