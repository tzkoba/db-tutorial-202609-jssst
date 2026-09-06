#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/01-start.sh"
"${SCRIPT_DIR}/02-insert.sh"
"${SCRIPT_DIR}/03-query.sh"
"${SCRIPT_DIR}/04-update.sh"
"${SCRIPT_DIR}/05-schema-flex.sh"

echo
echo "All phases finished. Run scripts/cleanup.sh when done."
