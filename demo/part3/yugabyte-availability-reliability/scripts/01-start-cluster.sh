#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

"${SCRIPT_DIR}/00-preflight.sh"

for name in $(yb_nodes); do
  if docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
    echo "コンテナ ${name} は既に存在します。先に cleanup.sh を実行してください。"
    exit 1
  fi
done

echo "イメージ ${YB_IMAGE} を pull しています（必要な場合）…"
docker pull "${YB_IMAGE}"

start_node() {
  local name="$1"
  local ysql_port="$2"
  local master_ui="$3"
  local tserver_ui="$4"
  shift 4
  local join_args=("$@")

  echo "${name} を起動しています（YSQL ホストポート ${ysql_port}）…"
  demo_run docker run -d --name "${name}" --hostname "${name}" --network "${YB_NETWORK}" \
    -p "${ysql_port}:5433" \
    -p "${master_ui}:7000" \
    -p "${tserver_ui}:9000" \
    "${YB_IMAGE}" \
    bin/yugabyted start \
      --base_dir="${YB_BASE_DIR}" \
      --background=false \
      "${join_args[@]}"
}

start_node "${YB1}" "${YB1_YSQL_PORT}" "${YB1_MASTER_UI_PORT}" "${YB1_TSERVER_UI_PORT}"
echo "${YB1} の YSQL を待っています…"
wait_for_ysql "${YB1}"

start_node "${YB2}" "${YB2_YSQL_PORT}" "${YB2_MASTER_UI_PORT}" "${YB2_TSERVER_UI_PORT}" \
  --join="${YB1}"
echo "${YB2} の YSQL を待っています…"
wait_for_ysql "${YB2}"

start_node "${YB3}" "${YB3_YSQL_PORT}" "${YB3_MASTER_UI_PORT}" "${YB3_TSERVER_UI_PORT}" \
  --join="${YB1}"
echo "${YB3} の YSQL を待っています…"
wait_for_ysql "${YB3}"

echo "3 ノード universe（yb_servers）を待っています…"
wait_for_cluster_ready

# Ensure RF=3 / placement once three nodes are up (idempotent if already configured).
echo "データ配置を設定しています（fault_tolerance=zone、RF=3）…"
demo_run docker exec "${YB1}" bin/yugabyted configure data_placement \
  --base_dir="${YB_BASE_DIR}" --fault_tolerance=zone || true

echo "yugabyted status（${YB1}）:"
demo_cmd docker exec "${YB1}" bin/yugabyted status --base_dir="${YB_BASE_DIR}"
docker exec "${YB1}" bin/yugabyted status --base_dir="${YB_BASE_DIR}" || true

echo "Phase 1 完了（yugabyted × 3 が参加済み）。"
