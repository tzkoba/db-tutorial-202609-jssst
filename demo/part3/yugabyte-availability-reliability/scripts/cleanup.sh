#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

docker rm -f "${YB1}" "${YB2}" "${YB3}" 2>/dev/null || true
rm -rf "${RUN_DIR}"

remove_net=false
if [[ "${FORCE:-}" == "1" || "${CI:-}" == "true" || "${YB_FORCE_CLEANUP:-}" == "1" ]]; then
  remove_net=true
elif [[ -t 0 ]]; then
  read -r -p "Remove network ${YB_NETWORK}? [y/N] " answer
  if [[ "${answer}" =~ ^[Yy]$ ]]; then
    remove_net=true
  fi
else
  remove_net=true
fi

if [[ "${remove_net}" == "true" ]]; then
  docker network rm "${YB_NETWORK}" 2>/dev/null || true
fi

echo "Cleanup complete."
