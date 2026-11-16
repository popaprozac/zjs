// An object's own properties listed and copied: Object.keys, values,
// and entries, for-in, Object.assign, and spread, on a record of eight
// properties and one of three. The work runs in a function, as most
// code does.
function run() {
  var record = { id: 1, name: "n", kind: "k", size: 4, tags: null, open: true, left: 7, top: 8 };
  var small = { x: 1, y: 2, z: 3 };
  var keys = Object.keys, values = Object.values, entries = Object.entries, assign = Object.assign, total = 0;
  for (var i = 0; i < 20000; i++) {
    total = (total + keys(record).length + values(record)[3] + entries(small)[i % 3][1] + keys(small).length) | 0;
    for (var name in record) total = (total + name.length) | 0;
    var copy = { ...record, extra: i }, merged = assign({}, small, record);
    total = (total + copy.extra + merged.size + merged.z) | 0;
  }
  return total;
}
var result = run();
