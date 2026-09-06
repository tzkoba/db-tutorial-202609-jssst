#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.env
source "${SCRIPT_DIR}/common.env"
# shellcheck source=../../../demo-lib.sh
source "${SCRIPT_DIR}/../../../demo-lib.sh"

echo "Baseline insert with w:majority (no failure)..."
demo_mongosh "${MONGO1}" "
const dbn = db.getSiblingDB('${MONGO_DB}');
const res = dbn.${MONGO_COLL}.insertOne(
  { tag: 'baseline', at: new Date() },
  { writeConcern: { w: 'majority' } }
);
print('inserted=' + res.insertedId);
print('count=' + dbn.${MONGO_COLL}.countDocuments({ tag: 'baseline' }));
" "${MONGO_DB}"

echo "Phase 3 complete."
