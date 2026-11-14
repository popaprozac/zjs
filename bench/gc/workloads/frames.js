// A frame loop over a data model: 500,000 records live; each frame makes
// 8,000 short-lived objects, rewrites 200 records, and replaces 400.
// Prints the checksum, then the longest frame and the total in ms: the
// longest frame is the pause an embedder's user would see.
function run() {
  var store = [], total = 0, worst = 0;
  for (var i = 0; i < 500000; i++) store.push({ id: i, name: "item" + i, tags: [i % 7, i % 11], parent: null });
  for (var i = 1; i < store.length; i++) store[i].parent = store[(i * 7) % i];
  var begin = Date.now();
  for (var frame = 0; frame < 300; frame++) {
    var t0 = Date.now();
    for (var j = 0; j < 8000; j++) {
      var tmp = { x: j, y: frame, v: [j, j + 1] };
      total = (total + tmp.v[1] + store[(j * 13 + frame) % store.length].tags[0]) | 0;
    }
    for (var k = 0; k < 200; k++) store[(frame * 211 + k * 17) % store.length].name = "renamed" + frame;
    for (var r = 0; r < 400; r++) { var at = (frame * 401 + r * 31) % store.length; store[at] = { id: at, name: "new" + at, tags: [frame, r], parent: store[(at * 3) % store.length] }; }
    var took = Date.now() - t0;
    if (took > worst) worst = took;
  }
  return [total, worst, Date.now() - begin];
}
var out = run();
var result = out[0];
(typeof console !== "undefined" ? console.log : print)(String(result));
(typeof console !== "undefined" ? console.log : print)("worst-frame-ms " + out[1] + " total-ms " + out[2]);
