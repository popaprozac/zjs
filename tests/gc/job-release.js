// A job that has run holds nothing: a long settle loop keeps a small
// live set however many promises it has been through.
async function run() {
  var total = 0;
  for (var i = 0; i < 100000; i++) {
    var box = { i: i, pad: [i, i, i] };
    total += await box.i;
    total += (await Promise.resolve(box)).pad.length;
  }
  return total;
}
var chained = 0;
function chain(n) {
  if (n == 0) return;
  new Promise(function (resolve) { resolve({ n: n }); }).then(function (v) { chained += 1; chain(v.n - 1); });
}
chain(100000);
run().then(function (total) { console.log("settled", total, chained); });
