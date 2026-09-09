#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"

echo "Docker を確認しています…"
docker version >/dev/null

echo "ネットワークと実行ディレクトリを作成しています…"
docker network create "${MONGO_NETWORK}" 2>/dev/null || true
mkdir -p "${RUN_DIR}"

echo "事前確認完了。"
