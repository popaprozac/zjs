// Arrays spread and copied: 4 and 64 elements into array literals and
// into calls, and through Array.from with and without a function. The
// work runs in a function, as most code does.
function run() {
  var small = [1, 2, 3, 4], large = [];
  for (var k = 0; k < 64; k++) large.push(k);
  function sum4(a, b, c, d) { return a + b + c + d; }
  function twice(x) { return x * 2; }
  var from = Array.from, total = 0;
  for (var i = 0; i < 20000; i++) {
    var copy = [...small], joined = [i, ...small, ...large];
    total = (total + copy.length + joined[i & 63] + sum4(...small) + Math.max(...copy)) | 0;
    total = (total + [...large].length + from(large)[i & 63] + from(small, twice)[i & 3]) | 0;
  }
  return total;
}
var result = run();
