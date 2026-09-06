// Count one document by ObjectId. Params are data, not generated JS:
//   /tmp/demo-count-params.json  {"db","coll","oid", optional "readConcern"}
// mongosh --file async-rewrites countDocuments. Do not pass this through --eval.
const fs = require('fs');
const p = JSON.parse(fs.readFileSync('/tmp/demo-count-params.json', 'utf8'));
const filter = { _id: ObjectId(p.oid) };
const opts = p.readConcern ? { readConcern: { level: p.readConcern } } : {};
print(
  db.getSiblingDB(p.db).getCollection(p.coll).countDocuments(filter, opts)
);
