#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "Docker を確認しています…"
docker version >/dev/null

# Some containerized Docker hosts drop bridge ICC via bridge-nf + DOCKER DROP rules.
# Disable bridge netfilter so containers on the same user-defined bridge can reach each other.
if [[ "${YB_FIX_BRIDGE_NF:-1}" == "1" ]]; then
  if [[ -w /proc/sys/net/bridge/bridge-nf-call-iptables ]]; then
    echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1 || true
    sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null 2>&1 || true
  fi
fi

avail="$(available_mem_mb)"
echo "利用可能メモリ: ${avail} MB（目安: 約 2GB×3 ノードなら ${YB_MIN_AVAIL_MB} MB 以上）"
if [[ "${avail}" -lt "${YB_MIN_AVAIL_MB}" ]]; then
  echo "WARNING: 空きメモリが少ないです。YugabyteDB 3 ノードデモはノードあたり約 2GB RAM が必要なことが多いです。" >&2
  echo "         OOM や起動遅延を受け入れる場合のみ続行してください。" >&2
fi

echo "ネットワークと実行ディレクトリを作成しています…"
docker network create "${YB_NETWORK}" 2>/dev/null || true
mkdir -p "${RUN_DIR}"

echo "事前確認完了。"
