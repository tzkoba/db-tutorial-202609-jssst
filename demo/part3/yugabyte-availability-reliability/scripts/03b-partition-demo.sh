#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Phase 3.5: ネットワーク分断（docker network disconnect） ==="

leader="$(find_tablet_leader_container)"
echo "現在の tablet Leader（対象）: ${leader}"

others=()
for node in $(yb_nodes); do
  [[ "${node}" == "${leader}" ]] && continue
  if docker ps --format '{{.Names}}' | grep -qx "${node}"; then
    others+=("${node}")
  fi
done
echo "多数派側のノード: ${others[*]}"

if [[ "${#others[@]}" -lt 2 ]]; then
  echo "ERROR: RF=3 の多数派デモには、他に稼働ノードが 2 台以上必要です。"
  exit 1
fi

echo ""
echo "--- Leader（${leader}）を ${YB_NETWORK} から切断 ---"
demo_run docker network disconnect "${YB_NETWORK}" "${leader}"

echo "Raft 再選出／多数派側の書き込み可能化を待っています…"
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
  echo "ERROR: 多数派側が時間内に書き込み可能になりませんでした。${leader} を再接続します。"
  docker network connect "${YB_NETWORK}" "${leader}" || true
  exit 1
fi
echo "多数派側の書き込み可能エンドポイント: ${majority_ep}"

echo ""
echo "--- 多数派側への書き込み（成功する想定） ---"
demo_ysql "${majority_ep}" \
  "INSERT INTO ${YB_TABLE}(tag, payload) VALUES ('partition_test', 'majority_write') RETURNING id, tag;"

echo ""
echo "--- 分断されたノード（${leader}）: YSQL は失敗または COMMIT 拒否になり得る ---"
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
echo "隔離ノードへの書き込み結果（失敗／タイムアウト／DNS エラーを想定）:"
echo "${part_status}"

echo ""
echo "--- ${leader} を ${YB_NETWORK} に再接続 ---"
demo_run docker network connect "${YB_NETWORK}" "${leader}"

echo "クラスタの回復を待っています（多数派側から確認）…"
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
echo "多数派 ${majority_ep} から見える partition_test 行: ${verify_m:-?}"

verify_l="n/a"
if timeout 20 docker exec "${leader}" bin/ysqlsh -h "${leader}" -U "${YB_USER}" -d "${YB_DB}" -c 'SELECT 1' >/dev/null 2>&1; then
  verify_l="$(count_rows "${leader}" "tag = 'partition_test'" 2>/dev/null || echo '?')"
  echo "再参加した ${leader} から見える partition_test 行: ${verify_l}"
else
  echo "NOTE: 再参加した ${leader} の YSQL はまだ準備できていません（分断後によくある）。講義の論点には多数派側の確認で足りる。"
fi

new_leader="$(find_tablet_leader_container || true)"
echo "回復後の tablet Leader（best-effort）: ${new_leader}"

echo ""
echo "=== Phase 3.5 まとめ ==="
echo "1. tablet Leader をネットワーク切断で隔離した（プロセスは生きているが到達不能）"
echo "2. 多数派側が再選出し、COMMIT 済みの書き込みを受け付けた"
echo "3. 隔離された少数派は安全に COMMIT できなかった（エラー／タイムアウト／DNS）"
echo "4. 再接続後も多数派には partition_test 行が残っている（heal_ok=${heal_ok}）"
echo ""
echo "Phase 3.5 完了。"
