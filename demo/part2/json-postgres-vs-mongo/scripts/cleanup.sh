#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

section "クリーンアップ: コンテナとネットワークを停止／削除"

docker rm -f "${PG_CONTAINER}" "${MONGO_CONTAINER}" 2>/dev/null || true
docker network rm "${DEMO_NETWORK}" 2>/dev/null || true

echo "クリーンアップ完了。"
