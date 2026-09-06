// Tight insertOne loop for one docker exec. Params JSON path is set by the
// per-client wrapper (__demoBurstJson) so parallel clients do not share a file.
//   { db, coll, tag, client, w, durationMs }
const fs = require('fs');
const p = JSON.parse(fs.readFileSync(globalThis.__demoBurstJson, 'utf8'));
const coll = db.getSiblingDB(p.db).getCollection(p.coll);
const wc = { writeConcern: { w: p.w, wtimeout: 5000 } };
const end = Date.now() + p.durationMs;
let n = 0;
while (Date.now() < end) {
  try {
    const res = coll.insertOne(
      { tag: p.tag, client: p.client, n: n, at: new Date() },
      wc
    );
    print(res.insertedId.toHexString());
    n++;
  } catch (e) {
    break;
  }
}
