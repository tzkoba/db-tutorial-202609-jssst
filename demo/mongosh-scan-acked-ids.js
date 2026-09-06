// Compare acked _id hex strings to what is on this node.
//   /tmp/demo-scan-acked.json  { db, coll, oids: ["<24 hex>", ...], optional readConcern }
//
// countDocuments is the FOUND/MISSING count (awaited as its own statement).
// find().toArray() is chunked and not chained with .map(), so the mongosh
// rewriter does not leave a partial first batch (default 101) as "have".
const fs = require('fs');
const p = JSON.parse(fs.readFileSync('/tmp/demo-scan-acked.json', 'utf8'));
const seen = {};
const oids = [];
(p.oids || []).forEach(function (h) {
  if (typeof h === 'string' && /^[0-9a-fA-F]{24}$/.test(h) && !seen[h]) {
    seen[h] = 1;
    oids.push(h);
  }
});
const coll = db.getSiblingDB(p.db).getCollection(p.coll);
const objectIds = oids.map(function (h) { return ObjectId(h); });
const filter = { _id: { $in: objectIds } };
const countOpts = {};
const findOpts = { projection: { _id: 1 } };
if (p.readConcern) {
  countOpts.readConcern = { level: p.readConcern };
  findOpts.readConcern = { level: p.readConcern };
}
const foundCount = oids.length === 0 ? 0 : coll.countDocuments(filter, countOpts);
const haveSet = {};
const chunkSize = 100;
for (let i = 0; i < objectIds.length; i += chunkSize) {
  const chunk = objectIds.slice(i, i + chunkSize);
  const docs = coll.find({ _id: { $in: chunk } }, findOpts).toArray();
  for (let j = 0; j < docs.length; j++) {
    haveSet[docs[j]._id.toHexString()] = 1;
  }
}
const missing = oids.filter(function (h) { return !haveSet[h]; });
print('ACKED ' + oids.length);
print('FOUND ' + foundCount);
print('MISSING ' + (oids.length - foundCount));
print('SAMPLE_MISSING ' + (missing[0] || ''));
print('SAMPLE_FOUND ' + (oids.find(function (h) { return haveSet[h]; }) || ''));
missing.forEach(function (h) { print('LOST ' + h); });
