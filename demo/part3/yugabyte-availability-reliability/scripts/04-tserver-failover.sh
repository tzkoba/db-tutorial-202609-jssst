#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

SUCCESS_FILE="${RUN_DIR}/success-failover.txt"
MISSING_FILE="${RUN_DIR}/missing-failover.txt"
: > "${SUCCESS_FILE}"
: > "${MISSING_FILE}"

echo "=== Phase 4: Concurrent INSERT + tserver Leader kill (committed rows must remain) ==="

# Idempotent. After a previous SIGKILL, bring all three nodes back before re-running.
for name in $(yb_nodes); do
  if ! docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
    echo "Missing container ${name}. Re-run from 01-start-cluster.sh."
    exit 1
  fi
done
demo_run docker start "${YB1}" "${YB2}" "${YB3}"

echo "Waiting for a writable endpoint..."
sample_ep="$(wait_for_writable_endpoint)"
leader="$(find_tablet_leader_container)"
echo "Tablet Leader to kill: ${leader}"

demo_ysql "${sample_ep}" \
  "INSERT INTO ${YB_TABLE}(tag, client_id, n) VALUES ('failover', 0, 0) RETURNING id;"

run_insert_clients "${SUCCESS_FILE}" 3 25 "failover"
sleep 4

echo "Killing Leader container ${leader} with SIGKILL..."
demo_run docker kill -s KILL "${leader}"

echo "Waiting for clients to finish..."
wait_clients

echo "Waiting for a writable endpoint on surviving nodes..."
new_ep="$(wait_for_writable_endpoint)"
echo "Writable endpoint: ${new_ep}"

success_count="$(grep -cve '^$' "${SUCCESS_FILE}" || true)"
echo "Client-acked (COMMIT returned) inserts: ${success_count}"

missing=0
found=0
sample_found=""
while IFS= read -r id; do
  [[ -z "${id}" ]] && continue
  [[ "${id}" =~ ^[0-9]+$ ]] || continue
  exists="$(ysql_q "${new_ep}" "SELECT count(*) FROM ${YB_TABLE} WHERE id = ${id};" || echo 0)"
  if [[ "${exists}" == "1" ]]; then
    found=$((found + 1))
    if [[ -z "${sample_found}" ]]; then
      sample_found="${id}"
    fi
  else
    missing=$((missing + 1))
    echo "${id}" >> "${MISSING_FILE}"
  fi
done < "${SUCCESS_FILE}"

echo "Found after failover: ${found}"
echo "Missing (COMMIT returned but row gone): ${missing}"
if [[ -n "${sample_found}" ]]; then
  show_one_id_check "${new_ep}" "${sample_found}"
fi

if [[ "${missing}" -eq 0 && "${success_count}" -gt 0 ]]; then
  echo "SUCCESS: All client-acked commits survived Leader kill (Raft majority commit)."
elif [[ "${success_count}" -eq 0 ]]; then
  echo "WARNING: No successful commits recorded (cluster may have been unavailable). Re-run Phase 4."
  exit 1
else
  echo "UNEXPECTED: Some acked commits missing. Inspect ${MISSING_FILE}"
  exit 1
fi

echo "Phase 4 complete."
