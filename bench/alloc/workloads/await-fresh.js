// OPS 200000 : awaits of a fresh, already-fulfilled promise each time
async function run() { var t = 0; for (var i = 0; i < 200000; i++) { t += await Promise.resolve(i); } return t; }
run().then(function (v) { console.log(v); });
