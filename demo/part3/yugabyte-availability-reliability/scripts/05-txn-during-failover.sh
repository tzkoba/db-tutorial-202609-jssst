#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Phase 5（任意）: 複数 tablet トランザクション + tablet Leader 1 台を kill ==="

T1="${YB_TXN_T1}"
T2="${YB_TXN_T2}"
assert_sql_ident "${T1}"
assert_sql_ident "${T2}"

restart_stopped_nodes() {
  local n
  for n in $(yb_nodes); do
    if docker ps -a --format '{{.Names}}' | grep -qx "${n}"; then
      if ! docker ps --format '{{.Names}}' | grep -qx "${n}"; then
        echo "停止中のノード ${n} を再起動しています…"
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
    echo "YSQL 準備完了ノード: ${ready}/3"
    if [[ "${ready}" -ge 2 ]]; then
      return 0
    fi
    sleep 2
  done
  echo "WARNING: YSQL 準備完了が 2 ノード未満です。best-effort で続行します。"
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
echo "健全なノード: ${healthy[*]:-none}"
if [[ "${#healthy[@]}" -lt 2 ]]; then
  echo "ERROR: Phase 5 には健全なノードが 2 台以上必要です。01-start-cluster.sh からやり直してください。"
  exit 1
fi

ep="$(wait_for_writable_endpoint)"
echo "使うエンドポイント: ${ep}"

echo ""
echo "--- 非 colocate のテーブルを 2 つ作成（各 1 tablet） ---"
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

echo "tablet が現れるまで待っています…"
sleep 4
show_table_tablet_leaders "${ep}" "${T1}" "${T2}"

leader1="$(find_tablet_leader_container "${T1}")"
leader2="$(find_tablet_leader_container "${T2}")"
echo "tablet Leader ${T1}: ${leader1}"
echo "tablet Leader ${T2}: ${leader2}"

# Same node is fine: each table still has its own tablet/Leader. Killing that
# node takes down both Raft leaders at once; they re-elect independently.
kill_target="${leader2}"
if [[ "${leader1}" == "${leader2}" ]]; then
  echo "NOTE: 両方の tablet Leader が ${kill_target} 上にあります。kill すると両グループが落ち、それぞれ再選出します。"
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
echo "開いているトランザクション用のエンドポイント: ${ep}"
echo "kill する tablet Leader（${T2}）: ${kill_target}"

echo ""
echo "--- A) 複数 tablet にまたがる未 COMMIT の txn + tablet-Leader ノードを kill（中止、部分行なしを想定） ---"
before1="$(count_named_table "${ep}" "${T1}" "tag = 'txn_open'")"
before2="$(count_named_table "${ep}" "${T2}" "tag = 'txn_open'")"
echo "開始前の行数: ${T1}=${before1} ${T2}=${before2}"

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
echo "開いているトランザクション中に tablet-Leader ノード ${kill_target} を kill しています…"
if docker ps --format '{{.Names}}' | grep -qx "${kill_target}"; then
  demo_run docker kill -s KILL "${kill_target}" || true
fi

wait "${txn_pid}" || true
echo "未 COMMIT txn のクライアントログ（末尾）:"
tail -n 20 "${RUN_DIR}/txn-open.log" || true

echo "COMMIT 済み txn の確認前に ${kill_target} を再起動しています…"
demo_run docker start "${kill_target}" || true
restart_stopped_nodes

ep2="$(wait_for_writable_endpoint)"
after1="$(count_named_table "${ep2}" "${T1}" "tag = 'txn_open'")"
after2="$(count_named_table "${ep2}" "${T2}" "tag = 'txn_open'")"
echo ""
echo "--- 中断した複数 tablet txn の後の件数 ---"
demo_ysql "${ep2}" "
SELECT '${T1}' AS table_name, count(*) FROM ${T1} WHERE tag = 'txn_open'
UNION ALL
SELECT '${T2}', count(*) FROM ${T2} WHERE tag = 'txn_open';
"

if [[ "${after1}" == "${before1}" && "${after2}" == "${before2}" ]]; then
  echo "OK: 未 COMMIT の複数 tablet 作業は、どちらのテーブルにも残らなかった。"
elif [[ "${after1}" != "${before1}" && "${after2}" == "${before2}" ]] \
  || [[ "${after1}" == "${before1}" && "${after2}" != "${before2}" ]]; then
  echo "UNEXPECTED: 片方のテーブルにだけ部分行が出た（${T1} ${before1}->${after1}, ${T2} ${before2}->${after2}）。"
  exit 1
else
  echo "NOTE: 両方のテーブルが変わった（${T1} ${before1}->${after1}, ${T2} ${before2}->${after2}）。kill 前に COMMIT が終わった可能性。"
fi

echo ""
echo "--- B) 複数 tablet txn を COMMIT してから tablet Leader 1 台を kill（両テーブルに行が残る） ---"
restart_stopped_nodes
mapfile -t healthy_b < <(healthy_nodes)
if [[ "${#healthy_b[@]}" -lt 3 ]]; then
  echo "NOTE: 健全なのは ${#healthy_b[@]}/3 台。コンテナ再起動をもう一度試します…"
  for n in $(yb_nodes); do docker restart "${n}" >/dev/null 2>&1 || docker start "${n}" >/dev/null 2>&1 || true; done
  sleep 20
  restart_stopped_nodes
  mapfile -t healthy_b < <(healthy_nodes)
fi
if [[ "${#healthy_b[@]}" -lt 2 ]]; then
  echo "ERROR: COMMIT 後のフェイルオーバー確認には健全なノードが 2 台以上必要です。"
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
echo "kill 前の COMMIT 済み件数: ${T1}=${c1} ${T2}=${c2}"
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
  echo "NOTE: 健全なノードは 2 台だけ — COMMIT 後の kill では生存 1 台になり、RF=3 の書き込みは再起動まで止まることがある。"
fi

if [[ "$(find_tablet_leader_container "${T1}")" == "${kill2}" ]]; then
  echo "NOTE: 両方の tablet Leader が ${kill2} 上にあります。"
fi
echo "COMMIT 後に tablet-Leader ノード ${kill2} を kill しています…"
demo_run docker kill -s KILL "${kill2}" || true

ep4=""
if ep4="$(wait_for_writable_endpoint)"; then
  :
else
  echo "NOTE: 生存ノードがまだ書き込み不能（RF 多数派の可能性）。耐久性確認のため ${kill2} を再起動します…"
  demo_run docker start "${kill2}" || true
  restart_stopped_nodes
  ep4="$(wait_for_writable_endpoint)"
fi

a1="$(count_named_table "${ep4}" "${T1}" "tag = 'txn_committed'")"
a2="$(count_named_table "${ep4}" "${T2}" "tag = 'txn_committed'")"
echo ""
echo "--- tablet Leader 1 台を kill した後の件数 ---"
demo_ysql "${ep4}" "
SELECT '${T1}' AS table_name, count(*) FROM ${T1} WHERE tag = 'txn_committed'
UNION ALL
SELECT '${T2}', count(*) FROM ${T2} WHERE tag = 'txn_committed';
"

if [[ "${a1}" == "${c1}" && "${a2}" == "${c2}" && "${c1}" -ge 1 && "${c2}" -ge 1 ]]; then
  echo "SUCCESS: COMMIT 済みの複数 tablet トランザクションは tablet-Leader ノード kill 後も両テーブルに残った。"
else
  echo "UNEXPECTED: COMMIT 済み件数が一致しない（${T1} ${c1}->${a1}, ${T2} ${c2}->${a2}）"
  exit 1
fi

echo "最終的な Leader マップに 3 ノード全部を含めるため ${kill2} を再起動しています…"
demo_run docker start "${kill2}" || true
restart_stopped_nodes
ep5="$(wait_for_writable_endpoint)"
echo ""
echo "--- フェイルオーバー後の tablet Leader（役割は移る、各テーブルが再選出） ---"
show_table_tablet_leaders "${ep5}" "${T1}" "${T2}"

echo "Phase 5 完了。"
