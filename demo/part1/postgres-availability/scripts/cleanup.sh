#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"

echo "コンテナを停止して削除しています…"
docker rm -f "${PG_STANDBY}" 2>/dev/null || true
docker rm -f "${PG_PRIMARY}" 2>/dev/null || true

read -r -p "ボリューム ${PG_PRIMARY_VOLUME} と ${PG_STANDBY_VOLUME} を削除しますか？ [y/N] " answer
if [[ "${answer}" =~ ^[Yy]$ ]]; then
  docker volume rm "${PG_PRIMARY_VOLUME}" 2>/dev/null || true
  docker volume rm "${PG_STANDBY_VOLUME}" 2>/dev/null || true
  echo "ボリュームを削除しました。"
else
  echo "ボリュームは残しました。"
fi

read -r -p "ネットワーク ${PG_NETWORK} を削除しますか？ [y/N] " answer
if [[ "${answer}" =~ ^[Yy]$ ]]; then
  docker network rm "${PG_NETWORK}" 2>/dev/null || true
  echo "ネットワークを削除しました。"
else
  echo "ネットワークは残しました。"
fi

echo "クリーンアップ完了。"
