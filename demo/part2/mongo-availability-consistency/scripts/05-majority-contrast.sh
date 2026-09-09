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
      echo "${name} を再起動しています…"
      demo_run docker start "${name}"
    fi
  else
    echo "コンテナ ${name} が見つかりません。01-start-nodes.sh からやり直してください。"
    exit 1
  fi
done

echo "Replica Set の回復を待っています…"
sleep 8
primary="$(wait_for_primary)"
echo "現在の PRIMARY: ${primary}"

SUCCESS_FILE="${RUN_DIR}/success-majority.txt"
MISSING_FILE="${RUN_DIR}/missing-majority.txt"
: > "${SUCCESS_FILE}"
: > "${MISSING_FILE}"

echo "=== Phase 5: w:majority 書き込み + PRIMARY を kill ==="
run_insert_clients "'majority'" "${SUCCESS_FILE}" 3 25
sleep 3

primary="$(wait_for_primary)"
echo "PRIMARY ${primary} を SIGKILL で止めます…"
demo_run docker kill -s KILL "${primary}"

wait_clients

echo "新しい PRIMARY を待っています…"
new_primary="$(wait_for_primary)"
echo "新しい PRIMARY: ${new_primary}"
echo "新しい PRIMARY の横に SECONDARY が出るまで待っています…"
wait_for_secondary_member "${new_primary}" || true

# w:majority means another surviving node already has the write. Checking only
# the new PRIMARY can look like a loss if that node has not applied it yet.
echo "生存レプリカ上で acked な _id を readConcern majority で確認しています…"
run_acked_id_scan_survivors "${SUCCESS_FILE}" "${MISSING_FILE}" "majority"
success_count="${scan_acked}"
found="${scan_found}"
missing="${scan_missing}"
sample_found="${scan_sample_found}"
echo "ACKED（w:majority で成功）: ${success_count}"

echo "FOUND（生存レプリカ、readConcern majority）: ${found}"
echo "MISSING（acked な w:majority 書き込みのうち）: ${missing}"
if [[ -n "${sample_found}" ]]; then
  show_one_id_check "${new_primary}" "${sample_found}" "majority"
fi

# One extra majority read of the same acked _ids. First-half waits stay as-is.
if [[ "${success_count}" -gt 0 && "${missing}" -gt 0 ]]; then
  echo "最初の majority 読みで MISSING > 0。committed snapshot 待ちで 10 秒おき、もう一度読みます…"
  sleep 10
  echo "同じ _id 集合を readConcern majority で再確認しています…"
  run_acked_id_scan_survivors "${SUCCESS_FILE}" "${MISSING_FILE}" "majority"
  success_count="${scan_acked}"
  found="${scan_found}"
  missing="${scan_missing}"
  sample_found="${scan_sample_found}"
  echo "ACKED（w:majority で成功）: ${success_count}"
  echo "FOUND（10 秒後の生存レプリカ、readConcern majority）: ${found}"
  echo "MISSING（10 秒後の acked な w:majority 書き込みのうち）: ${missing}"
  if [[ -n "${sample_found}" ]]; then
    show_one_id_check "${new_primary}" "${sample_found}" "majority"
  fi
fi

if [[ "${missing}" -eq 0 && "${success_count}" -gt 0 ]]; then
  echo "想定どおり: acked な w:majority 書き込みはフェイルオーバー後も残った。"
elif [[ "${success_count}" -eq 0 ]]; then
  echo "acked な majority 書き込みなし（フェイルオーバー中に失敗／タイムアウト）。w:1 との対比としてはこれも想定内。"
else
  echo "10 秒後の majority 再読みでも MISSING > 0。snapshot が追いついていない可能性。このデモでは許容。"
fi

echo "Phase 5 完了。"
