// OPS 200000 : values through for await over an async generator that awaits before each yield
async function* source(n) { for (var i = 0; i < n; i++) { await null; yield i; } }
async function run() { var t = 0; for await (var v of source(200000)) { t += v; } return t; }
run().then(function (v) { console.log(v); });
