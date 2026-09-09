#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"

docker rm -f "${MONGO1}" "${MONGO2}" "${MONGO3}" 2>/dev/null || true
rm -rf "${RUN_DIR}"

read -r -p "ネットワーク ${MONGO_NETWORK} を削除しますか？ [y/N] " answer
if [[ "${answer}" =~ ^[Yy]$ ]]; then
  docker network rm "${MONGO_NETWORK}" 2>/dev/null || true
fi

echo "クリーンアップ完了。"
