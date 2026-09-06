#!/usr/bin/env bash
# Docker-free checks for 04/05 _id lookups.
# The lookup must be a committed mongosh --file script plus JSON params,
# not generated --eval JS (rewriter + bson ObjectId keep rejecting those).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demo-lib.sh
source "${ROOT}/demo-lib.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

SCRIPT="${ROOT}/mongosh-count-by-oid.js"
[[ -f "${SCRIPT}" ]] || fail "missing ${SCRIPT}"

if type demo_mongosh_count_by_oid_js >/dev/null 2>&1; then
  fail "demo_mongosh_count_by_oid_js must not exist; do not generate --eval JS"
fi

if sed -n '/^demo_mongosh_count_by_oid()/,/^}/p' "${ROOT}/demo-lib.sh" | grep -q -- '--eval'; then
  fail "demo_mongosh_count_by_oid must not call mongosh --eval"
fi

if grep -qE '[0-9a-fA-F]{24}' "${SCRIPT}"; then
  fail "static script must not contain a 24-char hex literal"
fi
grep -q 'ObjectId(p.oid)' "${SCRIPT}" || fail "static script must pass p.oid to ObjectId"
grep -q "readFileSync('/tmp/demo-count-params.json'" "${SCRIPT}" || fail "static script must read JSON params"

OID="68ab00000000000000000001"
PARAMS="$(printf '{"db":"%s","coll":"%s","oid":"%s"}\n' "demo" "writes" "${OID}")"
node -e 'JSON.parse(process.argv[1])' "${PARAMS}" >/dev/null || fail "params JSON is invalid: ${PARAMS}"

export TEST_OID="${OID}"
export TEST_PARAMS="${PARAMS}"
export TEST_SCRIPT="${SCRIPT}"

node <<'NODE'
'use strict';

const fs = require('fs');
const vm = require('vm');

function stripQuotes(js) {
  return js.replace(/['"]/g, '');
}

function ObjectId(input) {
  if (typeof input !== 'string' || !/^[0-9a-fA-F]{24}$/.test(input)) {
    throw new Error(
      'BSONError: input must be a 24 character hex string, 12 byte Uint8Array, or an integer'
    );
  }
  return { hex: input.toLowerCase() };
}

function assertThrows(fn, re, label) {
  try {
    fn();
  } catch (err) {
    if (re.test(String(err))) {
      console.log(`ok  ${label}`);
      return;
    }
    throw new Error(`${label}: threw ${err}, expected ${re}`);
  }
  throw new Error(`${label}: expected throw`);
}

const oid = process.env.TEST_OID;
const paramsJson = process.env.TEST_PARAMS;
const src = fs.readFileSync(process.env.TEST_SCRIPT, 'utf8');

let seen;
let seenOpts;
const db = {
  getSiblingDB(name) {
    if (name !== 'demo') {
      throw new Error(`unexpected db name ${name}`);
    }
    return {
      getCollection(coll) {
        if (coll !== 'writes') {
          throw new Error(`unexpected coll ${coll}`);
        }
        return {
          countDocuments(q, opts) {
            seen = q._id;
            seenOpts = opts;
            return 1;
          }
        };
      }
    };
  }
};

vm.runInNewContext(src, {
  require(name) {
    if (name !== 'fs') {
      throw new Error(`unexpected require ${name}`);
    }
    return {
      readFileSync(path) {
        if (!String(path).includes('demo-count-params.json')) {
          throw new Error(`unexpected path ${path}`);
        }
        return paramsJson;
      }
    };
  },
  db,
  ObjectId,
  print(x) {
    return x;
  }
});

if (!seen || seen.hex !== oid) {
  throw new Error(`ObjectId got ${JSON.stringify(seen)}, expected hex ${oid}`);
}
if (seenOpts && seenOpts.readConcern) {
  throw new Error(`default count must omit readConcern, got ${JSON.stringify(seenOpts)}`);
}
console.log('ok  static --file script passes JSON oid string to ObjectId');

seen = null;
seenOpts = null;
vm.runInNewContext(src, {
  require() {
    return {
      readFileSync() {
        return JSON.stringify({
          db: 'demo',
          coll: 'writes',
          oid,
          readConcern: 'majority'
        });
      }
    };
  },
  db,
  ObjectId,
  print(x) {
    return x;
  }
});
if (!seenOpts || !seenOpts.readConcern || seenOpts.readConcern.level !== 'majority') {
  throw new Error(`majority count missing readConcern, got ${JSON.stringify(seenOpts)}`);
}
console.log('ok  count script applies readConcern majority when requested');

assertThrows(
  () => ObjectId(undefined),
  /24 character hex string/,
  'ObjectId(undefined) is BSONError (empty env / broken --eval IIFE)'
);

assertThrows(
  () => ObjectId(new Uint8Array([0x68, 0xab, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])),
  /24 character hex string|does not match the accept types/,
  'ObjectId(Uint8Array) is BSONError'
);

const quotedLiteral = `print(db.writes.countDocuments({ _id: ObjectId('${oid}') }))`;
assertThrows(
  () => new Function(stripQuotes(quotedLiteral)),
  /SyntaxError|Unexpected|identifier|token/i,
  'ObjectId(\'hex\') after quote-stripping is a SyntaxError'
);

const envJs = 'print(ObjectId(process.env.DEMO_OID))';
assertThrows(
  () =>
    new Function(
      'ObjectId',
      'print',
      'process',
      envJs
    )(ObjectId, (x) => x, { env: {} }),
  /24 character hex string/,
  'ObjectId(process.env.DEMO_OID) with empty env is BSONError'
);
NODE

echo "All mongosh ObjectId lookup checks passed."

# shellcheck source=part2/mongo-availability-consistency/scripts/lib.sh
source "${ROOT}/part2/mongo-availability-consistency/scripts/lib.sh"

expect_oid() {
  local got="$1"
  local want="$2"
  local label="$3"
  [[ "${got}" == "${want}" ]] || fail "${label}: got '${got}', want '${want}'"
  echo "ok  ${label}"
}

OID="68ab00000000000000000001"
expect_oid "$(normalize_oid "${OID}")" "${OID}" "plain hex"
expect_oid "$(normalize_oid "ObjectId(\"${OID}\")")" "${OID}" 'ObjectId("hex")'
expect_oid "$(normalize_oid "ObjectId('${OID}')")" "${OID}" "ObjectId('hex')"
expect_oid "$(normalize_oid "undefined")" "" "undefined only"
expect_oid "$(normalize_oid "${OID}"$'\n'"undefined")" "${OID}" "print(hex) then --eval undefined"
expect_oid "$(normalize_oid "undefined"$'\n'"${OID}")" "${OID}" "undefined then hex"
expect_oid "$(extract_oid_hex "${OID}"$'\n'"undefined")" "${OID}" "extract print+undefined"

OID2="68ab00000000000000000002"
all="$(printf '%s\nundefined\n%s\n' "${OID}" "${OID2}" | extract_oid_hex_all | tr '\n' ' ')"
[[ "${all}" == "${OID} ${OID2} " ]] || fail "extract_oid_hex_all: got '${all}'"
echo "ok  extract_oid_hex_all keeps every hex"

embedded="$(printf 'MongoServerError around %s in a crash line\n%s\n' "${OID}" "${OID2}" | extract_oid_hex_all | tr '\n' ' ')"
[[ "${embedded}" == "${OID2} " ]] || fail "extract_oid_hex_all must ignore embedded hex: '${embedded}'"
echo "ok  extract_oid_hex_all ignores hex inside error text"

if grep -q 'insertOne' "${ROOT}/part2/mongo-availability-consistency/scripts/lib.sh" \
  && grep -A80 '^run_insert_clients()' "${ROOT}/part2/mongo-availability-consistency/scripts/lib.sh" \
  | grep -q -- '--eval'; then
  fail "hidden insert clients must not use mongosh --eval per insert"
fi

export TEST_BURST="${ROOT}/mongosh-insert-burst.js"
export TEST_SCAN="${ROOT}/mongosh-scan-acked-ids.js"
export TEST_OID="${OID}"
export TEST_OID2="${OID2}"

node <<'NODE'
'use strict';

const fs = require('fs');
const vm = require('vm');

const oid = process.env.TEST_OID;
const oid2 = process.env.TEST_OID2;

let inserts = 0;
const printed = [];
const context = {
  globalThis: {},
  require() {
    return {
      readFileSync() {
        return JSON.stringify({
          db: 'demo',
          coll: 'writes',
          tag: 'wc_1',
          client: 1,
          w: 1,
          durationMs: 60000
        });
      }
    };
  },
  db: {
    getSiblingDB() {
      return {
        getCollection() {
          return {
            insertOne() {
              inserts += 1;
              if (inserts > 5) {
                throw new Error('primary killed');
              }
              const hex = oid.slice(0, 23) + String(inserts);
              return { insertedId: { toHexString: () => hex } };
            }
          };
        }
      };
    }
  },
  print(line) {
    printed.push(String(line));
  }
};
context.__demoBurstJson = '/tmp/demo-insert-burst-1.json';
context.globalThis = context;
vm.runInNewContext(fs.readFileSync(process.env.TEST_BURST, 'utf8'), context);
if (inserts !== 6) {
  throw new Error(`burst insertOne calls ${inserts}, want 6 (5 ok + 1 throw)`);
}
if (printed.length !== 5) {
  throw new Error(`burst printed ${printed.length} ids, want 5`);
}
console.log('ok  insert burst runs multiple insertOne in one script');

function runScan(params, haveHex) {
  const scanPrinted = [];
  const seen = { countOpts: null, findOpts: null };
  vm.runInNewContext(fs.readFileSync(process.env.TEST_SCAN, 'utf8'), {
    require() {
      return {
        readFileSync() {
          return JSON.stringify(params);
        }
      };
    },
    ObjectId(h) {
      return { hex: h, toHexString() { return h; } };
    },
    db: {
      getSiblingDB() {
        return {
          getCollection() {
            return {
              countDocuments(_filter, opts) {
                seen.countOpts = opts;
                return haveHex.length;
              },
              find(_filter, opts) {
                seen.findOpts = opts;
                return {
                  toArray() {
                    return haveHex.map((h) => ({ _id: { toHexString: () => h } }));
                  }
                };
              }
            };
          }
        };
      }
    },
    print(line) {
      scanPrinted.push(String(line));
    }
  });
  return { text: scanPrinted.join('\n'), seen };
}

const haveHex = [oid];
const { text, seen } = runScan({ db: 'demo', coll: 'writes', oids: [oid, oid, oid2] }, haveHex);
if (
  !text.includes('ACKED 2') ||
  !text.includes('FOUND 1') ||
  !text.includes('MISSING 1') ||
  !text.includes('LOST ' + oid2)
) {
  throw new Error(`scan output unexpected:\n${text}`);
}
if (seen.countOpts && seen.countOpts.readConcern) {
  throw new Error(`default scan must omit readConcern, got ${JSON.stringify(seen.countOpts)}`);
}
console.log('ok  acked-id scan reports unique ACKED/FOUND/MISSING/LOST');

const majority = runScan(
  { db: 'demo', coll: 'writes', oids: [oid, oid2], readConcern: 'majority' },
  haveHex
);
if (
  !majority.seen.countOpts ||
  !majority.seen.countOpts.readConcern ||
  majority.seen.countOpts.readConcern.level !== 'majority' ||
  !majority.seen.findOpts ||
  !majority.seen.findOpts.readConcern ||
  majority.seen.findOpts.readConcern.level !== 'majority'
) {
  throw new Error(
    `majority scan missing readConcern, count=${JSON.stringify(majority.seen.countOpts)} find=${JSON.stringify(majority.seen.findOpts)}`
  );
}
console.log('ok  scan script applies readConcern majority when requested');
NODE

echo "All _id capture checks passed."
