#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Phase 3.5: Network partition (docker network disconnect) ==="

leader="$(find_tablet_leader_container)"
echo "Current tablet Leader (target): ${leader}"

others=()
for node in $(yb_nodes); do
  [[ "${node}" == "${leader}" ]] && continue
  if docker ps --format '{{.Names}}' | grep -qx "${node}"; then
    others+=("${node}")
  fi
done
echo "Majority-side nodes: ${others[*]}"

if [[ "${#others[@]}" -lt 2 ]]; then
  echo "ERROR: Need at least 2 other running nodes for RF=3 majority demo."
  exit 1
fi

echo ""
echo "--- Disconnecting Leader (${leader}) from ${YB_NETWORK} ---"
demo_run docker network disconnect "${YB_NETWORK}" "${leader}"

echo "Waiting for Raft re-election / majority-side writability..."
sleep 5

majority_ep=""
for i in $(seq 1 60); do
  for node in "${others[@]}"; do
    if docker exec "${node}" bin/ysqlsh -h "${node}" -U "${YB_USER}" -d "${YB_DB}" \
      -c "INSERT INTO ${YB_TABLE}(tag, payload) VALUES ('partition_probe', 't=${i}') RETURNING id;" \
      >/dev/null 2>&1; then
      majority_ep="${node}"
      break 2
    fi
  done
  sleep 2
done

if [[ -z "${majority_ep}" ]]; then
  echo "ERROR: Majority side did not become writable in time. Reconnecting ${leader}."
  docker network connect "${YB_NETWORK}" "${leader}" || true
  exit 1
fi
echo "Majority-side writable endpoint: ${majority_ep}"

echo ""
echo "--- Write on majority side (must succeed) ---"
demo_ysql "${majority_ep}" \
  "INSERT INTO ${YB_TABLE}(tag, payload) VALUES ('partition_test', 'majority_write') RETURNING id, tag;"

echo ""
echo "--- Partitioned node (${leader}): YSQL may fail or refuse commits ---"
# After network disconnect, Docker DNS for the container hostname may break; treat
# connection errors / timeouts as the expected minority-side outcome.
echo
echo "# ${leader}"
demo_print_sql \
  "SET statement_timeout = '8s'; INSERT INTO ${YB_TABLE}(tag, payload) VALUES ('partition_isolated', 'should_fail') RETURNING id;" \
  "${YB_DB}"
part_status="$(timeout 15 docker exec "${leader}" bin/ysqlsh -h "${leader}" -U "${YB_USER}" -d "${YB_DB}" \
  -c "SET statement_timeout = '8s'; INSERT INTO ${YB_TABLE}(tag, payload) VALUES ('partition_isolated', 'should_fail') RETURNING id;" \
  2>&1 | tr -d '\r' | tail -n 8 || true)"
echo "Isolated-node write result (expect failure / timeout / DNS error):"
echo "${part_status}"

echo ""
echo "--- Reconnecting ${leader} to ${YB_NETWORK} ---"
demo_run docker network connect "${YB_NETWORK}" "${leader}"

echo "Waiting for cluster to heal (verify from majority side)..."
sleep 8
heal_ok=0
for i in $(seq 1 30); do
  verify_m="$(count_rows "${majority_ep}" "tag = 'partition_test'" 2>/dev/null || true)"
  if [[ "${verify_m}" =~ ^[0-9]+$ && "${verify_m}" -ge 1 ]]; then
    heal_ok=1
    break
  fi
  sleep 2
done
echo "partition_test rows visible on majority ${majority_ep}: ${verify_m:-?}"

verify_l="n/a"
if timeout 20 docker exec "${leader}" bin/ysqlsh -h "${leader}" -U "${YB_USER}" -d "${YB_DB}" -c 'SELECT 1' >/dev/null 2>&1; then
  verify_l="$(count_rows "${leader}" "tag = 'partition_test'" 2>/dev/null || echo '?')"
  echo "partition_test rows visible on rejoined ${leader}: ${verify_l}"
else
  echo "NOTE: rejoined ${leader} YSQL not ready yet (common after partition); majority-side verify is enough for the lecture point."
fi

new_leader="$(find_tablet_leader_container || true)"
echo "Tablet Leader after heal (best-effort): ${new_leader}"

echo ""
echo "=== Phase 3.5 Summary ==="
echo "1. Tablet Leader was isolated via network disconnect (process alive, network unreachable)"
echo "2. Majority side re-elected and accepted COMMITTED writes"
echo "3. Isolated minority could not safely commit (error/timeout/DNS)"
echo "4. After reconnect, majority still has the partition_test row (heal_ok=${heal_ok})"
echo ""
echo "Phase 3.5 complete."
