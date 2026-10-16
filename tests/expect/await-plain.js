// Awaiting a value that is not an object takes exactly the one turn the
// specification gives it, whatever the value, in async functions and in
// async generators (await and yield), interleaved with awaits that do
// go through a promise and with plain then-tickers.
var log = [];
function ticker(name, n) { var p = Promise.resolve(); for (let i = 1; i <= n; i++) { p = p.then(function () { log.push(name + i); }); } }
ticker("t", 10);
async function plain(label, value) { log.push(label + " before"); var got = await value; log.push(label + " after " + String(got)); var again = await value; log.push(label + " again " + String(again)); return got; }
plain("number", 1).then(function (v) { log.push("number done " + v); });
plain("undefined", undefined);
plain("null", null);
plain("string", "s");
plain("boolean", false);
plain("symbol", Symbol("sym"));
plain("promise", Promise.resolve("p"));
plain("thenable", { then: function (ok) { ok("th"); } });
plain("object", { plain: true }).then(function (v) { log.push("object done " + JSON.stringify(v)); });
async function* source() { log.push("gen start"); var a = await 1; log.push("gen awaited " + a); var sent = yield 2; log.push("gen sent " + sent); yield await "three"; yield Promise.resolve(4); return 5; }
var it = source();
it.next().then(function (r) { log.push("next1 " + JSON.stringify(r)); });
it.next("x").then(function (r) { log.push("next2 " + JSON.stringify(r)); });
it.next().then(function (r) { log.push("next3 " + JSON.stringify(r)); });
it.next().then(function (r) { log.push("next4 " + JSON.stringify(r)); });
it.next().then(function (r) { log.push("next5 " + JSON.stringify(r)); });
(async function () { for await (var v of [1, "two", null]) { log.push("for await " + String(v)); } })();
(async function () { try { await 1; throw new Error("after a plain await"); } catch (e) { log.push("caught " + e.message); } finally { await 0; log.push("finally awaited"); } })();
ticker("u", 3);
function settle(n, done) { if (n == 0) { done(); } else { Promise.resolve().then(function () { settle(n - 1, done); }); } }
settle(16, function () { console.log(log.join("\n")); });
