// Names read off functions, as library code does all the time: a
// builtin's prototype method borrowed with `call`, a function called
// with `call` and with `apply`, and a function's arity and name. The
// work runs in a function, as most code does.
function run() {
  function add(a, b) { return a + b; }
  function scale(x) { return x * this.factor; }
  var self = { factor: 3 };
  var record = { a: 1, b: 2, c: 3 };
  var keys = ["a", "b", "x", "c"];
  var pair = [1, 2];
  var total = 0;
  for (var i = 0; i < 300000; i++) {
    if (Object.prototype.hasOwnProperty.call(record, keys[i & 3])) total = (total + 1) | 0;
    total = (total + scale.call(self, i & 15)) | 0;
    pair[0] = i & 7;
    total = (total + add.apply(null, pair)) | 0;
    total = (total + Array.prototype.indexOf.call(pair, 2) + add.length + add.name.length) | 0;
  }
  return total;
}
var result = run();
