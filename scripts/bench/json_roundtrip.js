// JSON parse + stringify roundtrip on a generated payload. Measures
// string parsing, object/array allocation, and the JSON encoder.
function makeRecord(i) {
  return {
    id: i,
    name: "user_" + i,
    score: i * 17 % 1000,
    flags: [i & 1 ? true : false, i & 2 ? true : false, i & 4 ? true : false],
    tags: ["alpha", "beta", "gamma", "delta"]
  };
}

let n = 800;
let records = [];
for (let i = 0; i < n; i = i + 1) records[i] = makeRecord(i);
let payload = JSON.stringify(records);

let total = 0;
let rounds = 10;
for (let r = 0; r < rounds; r = r + 1) {
  let parsed = JSON.parse(payload);
  let out = JSON.stringify(parsed);
  total = total + out.length;
}
total
