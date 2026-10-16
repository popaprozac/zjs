// A large live heap (400,000 records kept) with steady short-lived churn:
// what a long-running app with a data model does.
function run() {
  var store = [];
  for (var i = 0; i < 400000; i++) store.push({ id: i, name: "item" + i, tags: [i % 7, i % 11], parent: null });
  for (var i = 1; i < store.length; i++) store[i].parent = store[(i * 7) % i];
  var total = 0;
  for (var round = 0; round < 40; round++) {
    for (var j = 0; j < 20000; j++) {
      var tmp = { a: j, b: [j, j + 1], c: "t" + j };
      total = (total + tmp.b[1] + store[(j * 13 + round) % store.length].tags[0]) | 0;
    }
    store[round * 1000].name = "renamed" + round;
  }
  return total;
}
var t0 = Date.now(); var result = run(); var elapsed = Date.now() - t0;
(typeof console !== "undefined" ? console.log : print)(result + " " + elapsed);
