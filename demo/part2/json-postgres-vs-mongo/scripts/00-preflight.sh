#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

section "Phase 0: 事前確認"

echo "Docker を確認しています…"
docker version >/dev/null

if [[ ! -f "${DATA_FILE}" ]]; then
  echo "サンプルデータがありません: ${DATA_FILE}" >&2
  exit 1
fi

echo "ネットワーク ${DEMO_NETWORK} を作成しています（無い場合のみ）…"
docker network create "${DEMO_NETWORK}" 2>/dev/null || true

echo "サンプル JSON: ${DATA_FILE}"
echo "事前確認完了。"
