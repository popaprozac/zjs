// 200,000 long-lived objects, each repeatedly given a fresh object: the
// write barrier's slow half and the remembered set, and garbage that is
// reachable only from old cells until it is overwritten.
function run() {
  var size = 200000, old = [], total = 0;
  for (var i = 0; i < size; i++) old.push({ id: i, ref: null, count: 0 });
  for (var round = 0; round < 10; round++) {
    for (var j = 0; j < size; j++) {
      var o = old[(j * 7919 + round) % size];
      o.ref = { round: round, j: j };
      o.count = o.count + 1;
      total = (total + o.ref.j) | 0;
    }
  }
  return total;
}
var result = run();
(typeof console !== "undefined" ? console.log : print)(String(result));
