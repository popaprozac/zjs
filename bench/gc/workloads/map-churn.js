// Maps and Sets made and dropped, keyed by short-lived objects: cells
// that own storage outside the slot arena, which a sweep has to release.
function run() {
  var total = 0;
  for (var i = 0; i < 30000; i++) {
    var m = new Map(), s = new Set();
    for (var j = 0; j < 8; j++) { var key = { j: j }; m.set(key, i + j); s.add(key); }
    total = (total + m.size + s.size) | 0;
  }
  return total;
}
var result = run();
(typeof console !== "undefined" ? console.log : print)(String(result));
