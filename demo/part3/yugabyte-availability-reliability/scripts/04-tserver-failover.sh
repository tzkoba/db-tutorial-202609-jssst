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

echo "=== Phase 4: 並行 INSERT + tserver Leader を kill（COMMIT 済み行は残る想定） ==="

# Idempotent. After a previous SIGKILL, bring all three nodes back before re-running.
for name in $(yb_nodes); do
  if ! docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
    echo "コンテナ ${name} が見つかりません。01-start-cluster.sh からやり直してください。"
    exit 1
  fi
done
demo_run docker start "${YB1}" "${YB2}" "${YB3}"

echo "書き込み可能なエンドポイントを待っています…"
sample_ep="$(wait_for_writable_endpoint)"
leader="$(find_tablet_leader_container)"
echo "kill する tablet Leader: ${leader}"

demo_ysql "${sample_ep}" \
  "INSERT INTO ${YB_TABLE}(tag, client_id, n) VALUES ('failover', 0, 0) RETURNING id;"

run_insert_clients "${SUCCESS_FILE}" 3 25 "failover"
sleep 4

echo "Leader コンテナ ${leader} を SIGKILL で止めます…"
demo_run docker kill -s KILL "${leader}"

echo "クライアントの終了を待っています…"
wait_clients

echo "生存ノード上で書き込み可能なエンドポイントを待っています…"
new_ep="$(wait_for_writable_endpoint)"
echo "書き込み可能なエンドポイント: ${new_ep}"

success_count="$(grep -cve '^$' "${SUCCESS_FILE}" || true)"
echo "ACKED（COMMIT が返った insert）: ${success_count}"

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

echo "FOUND（フェイルオーバー後）: ${found}"
echo "MISSING（COMMIT は返ったが行が無い）: ${missing}"
if [[ -n "${sample_found}" ]]; then
  show_one_id_check "${new_ep}" "${sample_found}"
fi

if [[ "${missing}" -eq 0 && "${success_count}" -gt 0 ]]; then
  echo "SUCCESS: クライアントが ACK した COMMIT はすべて Leader kill 後も残った（Raft majority commit）。"
elif [[ "${success_count}" -eq 0 ]]; then
  echo "WARNING: 成功した COMMIT が記録されていません（クラスタが利用不能だった可能性）。Phase 4 を再実行してください。"
  exit 1
else
  echo "UNEXPECTED: acked な COMMIT の一部が MISSING です。${MISSING_FILE} を確認してください"
  exit 1
fi

echo "Phase 4 完了。"
