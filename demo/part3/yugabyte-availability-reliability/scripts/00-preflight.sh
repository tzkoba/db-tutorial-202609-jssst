#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "Checking Docker..."
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
echo "Available memory: ${avail} MB (recommended >= ${YB_MIN_AVAIL_MB} MB for ~2GB×3 nodes)"
if [[ "${avail}" -lt "${YB_MIN_AVAIL_MB}" ]]; then
  echo "WARNING: Low free memory. YugabyteDB 3-node demos often need ~2GB RAM per node." >&2
  echo "         Continue only if you accept OOM / slow startup risk." >&2
fi

echo "Creating network and run directory..."
docker network create "${YB_NETWORK}" 2>/dev/null || true
mkdir -p "${RUN_DIR}"

echo "Preflight complete."
