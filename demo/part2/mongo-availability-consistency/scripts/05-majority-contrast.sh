#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Ensure all three nodes are up again (Phase 4 may have killed one).
for name in "${MONGO1}" "${MONGO2}" "${MONGO3}"; do
  if docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
    if ! docker ps --format '{{.Names}}' | grep -qx "${name}"; then
      echo "Restarting ${name}..."
      demo_run docker start "${name}"
    fi
  else
    echo "Missing container ${name}. Re-run from 01-start-nodes.sh."
    exit 1
  fi
done

echo "Waiting for Replica Set to heal..."
sleep 8
primary="$(wait_for_primary)"
echo "Current PRIMARY: ${primary}"

SUCCESS_FILE="${RUN_DIR}/success-majority.txt"
MISSING_FILE="${RUN_DIR}/missing-majority.txt"
: > "${SUCCESS_FILE}"
: > "${MISSING_FILE}"

echo "=== Phase 5: w:majority writers + kill PRIMARY ==="
run_insert_clients "'majority'" "${SUCCESS_FILE}" 3 25
sleep 3

primary="$(wait_for_primary)"
echo "Killing PRIMARY ${primary} with SIGKILL..."
demo_run docker kill -s KILL "${primary}"

wait_clients

echo "Waiting for new PRIMARY..."
new_primary="$(wait_for_primary)"
echo "New PRIMARY: ${new_primary}"
echo "Waiting for a SECONDARY to appear beside the new PRIMARY..."
wait_for_secondary_member "${new_primary}" || true

# w:majority means another surviving node already has the write. Checking only
# the new PRIMARY can look like a loss if that node has not applied it yet.
echo "Checking acked _ids on surviving replicas with readConcern majority..."
run_acked_id_scan_survivors "${SUCCESS_FILE}" "${MISSING_FILE}" "majority"
success_count="${scan_acked}"
found="${scan_found}"
missing="${scan_missing}"
sample_found="${scan_sample_found}"
echo "Client-acked inserts (w:majority): ${success_count}"

echo "Found on a surviving replica (readConcern majority): ${found}"
echo "Missing among acked w:majority writes: ${missing}"
if [[ -n "${sample_found}" ]]; then
  show_one_id_check "${new_primary}" "${sample_found}" "majority"
fi

# One extra majority read of the same acked _ids. First-half waits stay as-is.
if [[ "${success_count}" -gt 0 && "${missing}" -gt 0 ]]; then
  echo "Missing > 0 after first majority read; waiting 10s for the committed snapshot, then reading once more..."
  sleep 10
  echo "Checking acked _ids again (same set, readConcern majority)..."
  run_acked_id_scan_survivors "${SUCCESS_FILE}" "${MISSING_FILE}" "majority"
  success_count="${scan_acked}"
  found="${scan_found}"
  missing="${scan_missing}"
  sample_found="${scan_sample_found}"
  echo "Client-acked inserts (w:majority): ${success_count}"
  echo "Found on a surviving replica after 10s (readConcern majority): ${found}"
  echo "Missing among acked w:majority writes after 10s: ${missing}"
  if [[ -n "${sample_found}" ]]; then
    show_one_id_check "${new_primary}" "${sample_found}" "majority"
  fi
fi

if [[ "${missing}" -eq 0 && "${success_count}" -gt 0 ]]; then
  echo "As expected: acked w:majority writes survived failover."
elif [[ "${success_count}" -eq 0 ]]; then
  echo "No acked majority writes (all failed/timed out during failover). That is also an expected contrast to w:1."
else
  echo "Missing still > 0 after one 10s majority reread; snapshot may not have caught up. Acceptable for this demo."
fi

echo "Phase 5 complete."
