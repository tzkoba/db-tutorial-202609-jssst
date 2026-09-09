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

echo "=== Phase 4: w:1 書き込み + PRIMARY を kill ==="
# Idempotent: running nodes stay up; a node SIGKILL'd by a previous Phase 4 comes back.
# Re-running 04 without this leaves only two members, then the next kill loses majority.
demo_run docker start "${MONGO1}" "${MONGO2}" "${MONGO3}"
echo "Replica Set メンバの準備を待っています…"
sleep 8
primary="$(wait_for_primary)"
echo "現在の PRIMARY: ${primary}"

run_insert_clients "1" "${SUCCESS_FILE}" 3 25
sleep 3

echo "PRIMARY ${primary} を SIGKILL で止めます…"
demo_run docker kill -s KILL "${primary}"

echo "クライアントの終了を待っています…"
wait_clients

echo "新しい PRIMARY を待っています…"
new_primary="$(wait_for_primary)"
echo "新しい PRIMARY: ${new_primary}"

echo "acked な _id を readConcern local で確認しています…"
run_acked_id_scan "${new_primary}" "${SUCCESS_FILE}" "${MISSING_FILE}" "local"
success_count="${scan_acked}"
found="${scan_found}"
missing="${scan_missing}"
sample_missing="${scan_sample_missing}"
sample_found="${scan_sample_found}"
echo "ACKED（クライアントが成功を受け取った insert）: ${success_count}"

echo "FOUND（新 PRIMARY 上、readConcern local）: ${found}"
echo "MISSING（acked だが失われた）: ${missing}"
if [[ -n "${sample_missing}" ]]; then
  show_one_id_check "${new_primary}" "${sample_missing}" "local"
elif [[ -n "${sample_found}" ]]; then
  show_one_id_check "${new_primary}" "${sample_found}" "local"
fi
if [[ "${missing}" -gt 0 ]]; then
  echo "w:1 では、acked した書き込みが失われることがある、という実演。"
  echo "MISSING の ID は ${MISSING_FILE} にあります"
else
  echo "今回は損失なし（SIGKILL 前に SECONDARY へ w:1 が適用されていた可能性）。"
  echo "必要ならこのスクリプトを再実行してください（先に ${MONGO1} ${MONGO2} ${MONGO3} を起動します）。"
fi

echo "Phase 4 完了。"
