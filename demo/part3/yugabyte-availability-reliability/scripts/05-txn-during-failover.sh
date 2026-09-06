#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Phase 5 (optional): Multi-tablet transaction + one tablet Leader kill ==="

T1="${YB_TXN_T1}"
T2="${YB_TXN_T2}"
assert_sql_ident "${T1}"
assert_sql_ident "${T2}"

restart_stopped_nodes() {
  local n
  for n in $(yb_nodes); do
    if docker ps -a --format '{{.Names}}' | grep -qx "${n}"; then
      if ! docker ps --format '{{.Names}}' | grep -qx "${n}"; then
        echo "Restarting stopped node ${n}..."
        docker start "${n}" >/dev/null
      fi
    fi
  done
  local i
  for i in $(seq 1 45); do
    local ready=0
    for n in $(yb_nodes); do
      if timeout 8 docker exec "${n}" bin/ysqlsh -h "${n}" -U "${YB_USER}" -d "${YB_DB}" \
        -c 'SELECT 1' >/dev/null 2>&1; then
        ready=$((ready + 1))
      fi
    done
    echo "YSQL-ready nodes: ${ready}/3"
    if [[ "${ready}" -ge 2 ]]; then
      return 0
    fi
    sleep 2
  done
  echo "WARNING: fewer than 2 nodes became YSQL-ready; continuing best-effort."
}

healthy_nodes() {
  local n
  for n in $(yb_nodes); do
    if docker ps --format '{{.Names}}' | grep -qx "${n}" \
      && timeout 8 docker exec "${n}" bin/ysqlsh -h "${n}" -U "${YB_USER}" -d "${YB_DB}" \
        -c 'SELECT 1' >/dev/null 2>&1; then
      echo "${n}"
    fi
  done
}

restart_stopped_nodes

mapfile -t healthy < <(healthy_nodes)
echo "Healthy nodes: ${healthy[*]:-none}"
if [[ "${#healthy[@]}" -lt 2 ]]; then
  echo "ERROR: Need at least 2 healthy nodes for Phase 5. Re-run 01-start-cluster.sh."
  exit 1
fi

ep="$(wait_for_writable_endpoint)"
echo "Using endpoint: ${ep}"

echo ""
echo "--- Creating two non-colocated tables (1 tablet each) ---"
demo_ysql "${ep}" <<SQL
DROP TABLE IF EXISTS ${T2};
DROP TABLE IF EXISTS ${T1};
CREATE TABLE ${T1} (
  id BIGSERIAL PRIMARY KEY,
  tag TEXT NOT NULL,
  payload TEXT DEFAULT ''
) WITH (COLOCATION = false)
SPLIT INTO 1 TABLETS;
CREATE TABLE ${T2} (
  id BIGSERIAL PRIMARY KEY,
  tag TEXT NOT NULL,
  payload TEXT DEFAULT ''
) WITH (COLOCATION = false)
SPLIT INTO 1 TABLETS;
SQL

echo "Waiting for tablets to appear..."
sleep 4
show_table_tablet_leaders "${ep}" "${T1}" "${T2}"

leader1="$(find_tablet_leader_container "${T1}")"
leader2="$(find_tablet_leader_container "${T2}")"
echo "Tablet Leader ${T1}: ${leader1}"
echo "Tablet Leader ${T2}: ${leader2}"

# Same node is fine: each table still has its own tablet/Leader. Killing that
# node takes down both Raft leaders at once; they re-elect independently.
kill_target="${leader2}"
if [[ "${leader1}" == "${leader2}" ]]; then
  echo "NOTE: both tablet Leaders are on ${kill_target}. Killing it drops both groups; they re-elect separately."
fi

# Talk to a node that is not the tablet Leader we will kill, so the session
# can report the distributed-txn abort instead of just losing the TCP connection.
if [[ "${ep}" == "${kill_target}" ]]; then
  for n in "${healthy[@]}"; do
    if [[ "${n}" != "${kill_target}" ]]; then
      ep="${n}"
      break
    fi
  done
fi
echo "Endpoint for open transaction: ${ep}"
echo "Tablet Leader to kill (${T2}): ${kill_target}"

echo ""
echo "--- A) Open cross-tablet txn + kill a tablet-Leader node (expect abort, no partial rows) ---"
before1="$(count_named_table "${ep}" "${T1}" "tag = 'txn_open'")"
before2="$(count_named_table "${ep}" "${T2}" "tag = 'txn_open'")"
echo "Rows before: ${T1}=${before1} ${T2}=${before2}"

echo
echo "# ${ep}"
demo_print_sql "BEGIN;
INSERT INTO ${T1}(tag, payload) VALUES ('txn_open', 'orders');
INSERT INTO ${T2}(tag, payload) VALUES ('txn_open', 'lines');
SELECT pg_sleep(8);
COMMIT;" "${YB_DB}"

(
  timeout 40 docker exec -i "${ep}" bin/ysqlsh -h "${ep}" -U "${YB_USER}" -d "${YB_DB}" -v ON_ERROR_STOP=1 <<SQL || true
BEGIN;
INSERT INTO ${T1}(tag, payload) VALUES ('txn_open', 'orders');
INSERT INTO ${T2}(tag, payload) VALUES ('txn_open', 'lines');
SELECT pg_sleep(8);
COMMIT;
SQL
) > "${RUN_DIR}/txn-open.log" 2>&1 &
txn_pid=$!

sleep 2
echo "Killing tablet-Leader node ${kill_target} during open transaction..."
if docker ps --format '{{.Names}}' | grep -qx "${kill_target}"; then
  demo_run docker kill -s KILL "${kill_target}" || true
fi

wait "${txn_pid}" || true
echo "Open-txn client log (tail):"
tail -n 20 "${RUN_DIR}/txn-open.log" || true

echo "Restarting ${kill_target} before committed-txn check..."
demo_run docker start "${kill_target}" || true
restart_stopped_nodes

ep2="$(wait_for_writable_endpoint)"
after1="$(count_named_table "${ep2}" "${T1}" "tag = 'txn_open'")"
after2="$(count_named_table "${ep2}" "${T2}" "tag = 'txn_open'")"
echo ""
echo "--- Counts after interrupted cross-tablet txn ---"
demo_ysql "${ep2}" "
SELECT '${T1}' AS table_name, count(*) FROM ${T1} WHERE tag = 'txn_open'
UNION ALL
SELECT '${T2}', count(*) FROM ${T2} WHERE tag = 'txn_open';
"

if [[ "${after1}" == "${before1}" && "${after2}" == "${before2}" ]]; then
  echo "OK: Uncommitted cross-tablet work did not become durable on either table."
elif [[ "${after1}" != "${before1}" && "${after2}" == "${before2}" ]] \
  || [[ "${after1}" == "${before1}" && "${after2}" != "${before2}" ]]; then
  echo "UNEXPECTED: partial rows on one table only (${T1} ${before1}->${after1}, ${T2} ${before2}->${after2})."
  exit 1
else
  echo "NOTE: Both tables changed (${T1} ${before1}->${after1}, ${T2} ${before2}->${after2}). COMMIT may have finished before kill."
fi

echo ""
echo "--- B) COMMIT cross-tablet txn, then kill one tablet Leader (both tables keep the rows) ---"
restart_stopped_nodes
mapfile -t healthy_b < <(healthy_nodes)
if [[ "${#healthy_b[@]}" -lt 3 ]]; then
  echo "NOTE: Only ${#healthy_b[@]}/3 healthy; attempting container restarts once more..."
  for n in $(yb_nodes); do docker restart "${n}" >/dev/null 2>&1 || docker start "${n}" >/dev/null 2>&1 || true; done
  sleep 20
  restart_stopped_nodes
  mapfile -t healthy_b < <(healthy_nodes)
fi
if [[ "${#healthy_b[@]}" -lt 2 ]]; then
  echo "ERROR: Need at least 2 healthy nodes for post-commit failover check."
  exit 1
fi

ep3="$(wait_for_writable_endpoint)"

demo_ysql "${ep3}" <<SQL
BEGIN;
INSERT INTO ${T1}(tag, payload) VALUES ('txn_committed', 'orders');
INSERT INTO ${T2}(tag, payload) VALUES ('txn_committed', 'lines');
COMMIT;
SQL

c1="$(count_named_table "${ep3}" "${T1}" "tag = 'txn_committed'")"
c2="$(count_named_table "${ep3}" "${T2}" "tag = 'txn_committed'")"
echo "Committed counts before kill: ${T1}=${c1} ${T2}=${c2}"
demo_ysql "${ep3}" "
SELECT '${T1}' AS table_name, count(*) FROM ${T1} WHERE tag = 'txn_committed'
UNION ALL
SELECT '${T2}', count(*) FROM ${T2} WHERE tag = 'txn_committed';
"

kill2="$(find_tablet_leader_container "${T2}")"
if ! printf '%s\n' "${healthy_b[@]}" | grep -qx "${kill2}"; then
  kill2="${healthy_b[-1]}"
fi
if [[ "${#healthy_b[@]}" -eq 2 ]]; then
  echo "NOTE: Only 2 healthy nodes — post-commit kill leaves 1 survivor; RF=3 writes may pause until restart."
fi

if [[ "$(find_tablet_leader_container "${T1}")" == "${kill2}" ]]; then
  echo "NOTE: both tablet Leaders are on ${kill2}."
fi
echo "Killing tablet-Leader node ${kill2} after COMMIT..."
demo_run docker kill -s KILL "${kill2}" || true

ep4=""
if ep4="$(wait_for_writable_endpoint)"; then
  :
else
  echo "NOTE: Survivors not writable yet (likely RF majority). Restarting ${kill2} to verify durability..."
  demo_run docker start "${kill2}" || true
  restart_stopped_nodes
  ep4="$(wait_for_writable_endpoint)"
fi

a1="$(count_named_table "${ep4}" "${T1}" "tag = 'txn_committed'")"
a2="$(count_named_table "${ep4}" "${T2}" "tag = 'txn_committed'")"
echo ""
echo "--- Counts after killing one tablet Leader ---"
demo_ysql "${ep4}" "
SELECT '${T1}' AS table_name, count(*) FROM ${T1} WHERE tag = 'txn_committed'
UNION ALL
SELECT '${T2}', count(*) FROM ${T2} WHERE tag = 'txn_committed';
"

if [[ "${a1}" == "${c1}" && "${a2}" == "${c2}" && "${c1}" -ge 1 && "${c2}" -ge 1 ]]; then
  echo "SUCCESS: COMMITTED cross-tablet transaction survived tablet-Leader-node kill (both tables)."
else
  echo "UNEXPECTED: committed counts mismatch (${T1} ${c1}->${a1}, ${T2} ${c2}->${a2})"
  exit 1
fi

echo "Restarting ${kill2} so the final Leader map can include all three nodes..."
demo_run docker start "${kill2}" || true
restart_stopped_nodes
ep5="$(wait_for_writable_endpoint)"
echo ""
echo "--- Tablet Leaders after failover (roles move; each table re-elects) ---"
show_table_tablet_leaders "${ep5}" "${T1}" "${T2}"

echo "Phase 5 complete."
