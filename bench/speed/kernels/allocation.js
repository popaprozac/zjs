// Short-lived objects and arrays: allocation and collection.
// The work runs in a function, as most code does.
function run() {
  var keep = null;
  var total = 0;
  for (var i = 0; i < 400000; i++) {
    var o = { id: i, tags: [i, i + 1], next: keep };
    if (i % 1000 === 0) keep = null; else keep = o;
    total = (total + o.tags[1]) | 0;
  }
  return total;
}
var result = run();
