// Dense array fill, indexed sum, map/filter/reduce, and a numeric sort.
// The work runs in a function, as most code does.
function run() {
  var total = 0;
  for (var round = 0; round < 60; round++) {
    var a = [];
    for (var i = 0; i < 20000; i++) a.push((i * 7919 + round) % 10007);
    for (var j = 0; j < a.length; j++) total = (total + a[j]) | 0;
    total = (total + a.map(function (x) { return x * 2; }).filter(function (x) { return x % 3 === 0; }).reduce(function (s, x) { return s + x; }, 0)) | 0;
    if (round % 10 === 0) { a.sort(function (x, y) { return x - y; }); total = (total + a[100]) | 0; }
  }
  return total;
}
var result = run();
