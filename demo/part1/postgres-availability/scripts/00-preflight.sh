#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"

echo "Docker を確認しています…"
docker version >/dev/null

echo "ネットワークとボリュームを作成しています（無い場合のみ）…"
docker network create "${PG_NETWORK}" 2>/dev/null || true
docker volume create "${PG_PRIMARY_VOLUME}" >/dev/null
docker volume create "${PG_STANDBY_VOLUME}" >/dev/null

echo "事前確認完了。"
