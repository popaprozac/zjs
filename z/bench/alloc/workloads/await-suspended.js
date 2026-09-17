// OPS 100000 : awaits of a promise still pending at the await, settled by another coroutine
var resolveNext;
function tick() { return new Promise(function (resolve) { resolveNext = resolve; }); }
async function consumer() { var t = 0; for (var i = 0; i < 100000; i++) { t += await tick(); } return t; }
async function producer() { for (var i = 0; i < 100000; i++) { await null; resolveNext(i); } }
consumer().then(function (v) { console.log(v); });
producer();
