// OPS 200000 : awaits of a primitive
async function run() { var t = 0; for (var i = 0; i < 200000; i++) { t += await i; } return t; }
run().then(function (v) { console.log(v); });
