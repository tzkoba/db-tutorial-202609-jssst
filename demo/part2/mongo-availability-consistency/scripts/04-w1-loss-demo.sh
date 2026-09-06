#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

SUCCESS_FILE="${RUN_DIR}/success-w1.txt"
MISSING_FILE="${RUN_DIR}/missing-w1.txt"
: > "${SUCCESS_FILE}"
: > "${MISSING_FILE}"

echo "=== Phase 4: w:1 writers + kill PRIMARY ==="
# Idempotent: running nodes stay up; a node SIGKILL'd by a previous Phase 4 comes back.
# Re-running 04 without this leaves only two members, then the next kill loses majority.
demo_run docker start "${MONGO1}" "${MONGO2}" "${MONGO3}"
echo "Waiting for replica set members to be ready..."
sleep 8
primary="$(wait_for_primary)"
echo "Current PRIMARY: ${primary}"

run_insert_clients "1" "${SUCCESS_FILE}" 3 25
sleep 3

echo "Killing PRIMARY ${primary} with SIGKILL..."
demo_run docker kill -s KILL "${primary}"

echo "Waiting for clients to finish..."
wait_clients

echo "Waiting for new PRIMARY..."
new_primary="$(wait_for_primary)"
echo "New PRIMARY: ${new_primary}"

echo "Checking acked _ids with readConcern local..."
run_acked_id_scan "${new_primary}" "${SUCCESS_FILE}" "${MISSING_FILE}" "local"
success_count="${scan_acked}"
found="${scan_found}"
missing="${scan_missing}"
sample_missing="${scan_sample_missing}"
sample_found="${scan_sample_found}"
echo "Client-acked inserts: ${success_count}"

echo "Found on new PRIMARY (readConcern local): ${found}"
echo "Missing (acked but lost): ${missing}"
if [[ -n "${sample_missing}" ]]; then
  show_one_id_check "${new_primary}" "${sample_missing}" "local"
elif [[ -n "${sample_found}" ]]; then
  show_one_id_check "${new_primary}" "${sample_found}" "local"
fi
if [[ "${missing}" -gt 0 ]]; then
  echo "Demonstrated acknowledged-write loss under w:1."
  echo "Missing IDs listed in ${MISSING_FILE}"
else
  echo "No loss detected this run (local secondaries may still apply w:1 before SIGKILL)."
  echo "Re-run this script if needed (it starts ${MONGO1} ${MONGO2} ${MONGO3} first)."
fi

echo "Phase 4 complete."
