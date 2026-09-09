#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"

echo "Docker を確認しています…"
docker version >/dev/null

echo "ボリュームを作成しています（無い場合のみ）…"
docker volume create "${PG_DATA_VOLUME}" >/dev/null
docker volume create "${PG_PITR_DATA_VOLUME}" >/dev/null
docker volume create "${PG_ARCHIVE_VOLUME}" >/dev/null
docker volume create "${PG_BACKUP_VOLUME}" >/dev/null

echo "事前確認完了。"
