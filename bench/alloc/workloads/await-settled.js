// OPS 200000 : awaits of one already-fulfilled promise
var settled = Promise.resolve(3);
async function run() { var t = 0; for (var i = 0; i < 200000; i++) { t += await settled; } return t; }
run().then(function (v) { console.log(v); });
