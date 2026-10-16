// Async yield* delegation, as event traces: an async generator delegate
// and the AsyncFromSync fallback (next(v) forwarded, completion value); a
// custom async iterator's observable call and getter order; return
// forwarded with done:false continuing and with done:true finishing through
// finally; a missing return; throw forwarded; a missing throw closing the
// iterator with its own error winning, else a TypeError; invalid results,
// non-callable and rejecting methods; mixed queued requests while the
// delegate's next is pending, with a thenable value; forced collections
// while suspended in the delegation.
// Async yield* delegation, as event traces.
var log = [];
function J(v) { return typeof v === "object" && v !== null ? JSON.stringify(v) : String(v); }
async function main() {
  // 1. async generator delegate: next(v)/throw/return forwarded, completion value
  { async function* inner() { var a = yield 1; var b = yield a + 10; return "ret:" + b; } async function* outer() { var v = yield* inner(); yield v; } var g = outer(); var r = [await g.next(), await g.next(5), await g.next(7), await g.next()]; log.push("t1 " + r.map(J).join(" ")); }
  // 2. AsyncFromSync fallback: sync generator with promise values awaited, next(v) forwarded
  { function* sync() { var a = yield Promise.resolve("p1"); yield "got " + a; return "sync-done"; } async function* g() { var v = yield* sync(); yield v; } var it = g(); log.push("t2 " + [await it.next(), await it.next("A"), await it.next(), await it.next()].map(J).join(" ")); }
  // 3. custom async iterator: observable call/getter order
  { var t = []; var iter = { [Symbol.asyncIterator]() { t.push("asyncIterator"); return this; }, next(v) { t.push("next(" + v + ")"); return { get done() { t.push("done?"); return v === "stop"; }, get value() { t.push("value?"); return "v-" + v; } }; } }; async function* g() { var r = yield* iter; t.push("expr=" + r); } var it = g(); await it.next(); await it.next("x"); await it.next("stop"); log.push("t3 " + t.join()); }
  // 4. return forwarded: delegate's return reports done:false, delegation continues
  { var iter = { [Symbol.asyncIterator]() { return this; }, next() { return Promise.resolve({ value: "n", done: false }); }, return(v) { return { value: "still-" + v, done: false }; } }; async function* g() { yield* iter; } var it = g(); await it.next(); var a = await it.return("x"); var b = await it.next(); log.push("t4 " + J(a) + " " + J(b)); }
  // 5. return forwarded and done: outer returns the awaited value through finally
  { var t = []; var iter = { [Symbol.asyncIterator]() { return this; }, next() { return { value: 1, done: false }; }, return(v) { t.push("delegate-return"); return { value: Promise.resolve("awaited-" + v), done: true }; } }; async function* g() { try { yield* iter; } finally { t.push("outer-finally"); } } var it = g(); await it.next(); var r = await it.return("R"); log.push("t5 " + t.join() + " " + J(r)); }
  // 6. missing return: outer returns the (awaited) received value
  { var iter = { [Symbol.asyncIterator]() { return this; }, next() { return { value: 1, done: false }; } }; var t = []; async function* g() { try { yield* iter; } finally { t.push("fin"); } } var it = g(); await it.next(); var r = await it.return(Promise.resolve("gone")); log.push("t6 " + t.join() + " " + J(r)); }
  // 7. throw forwarded; missing throw closes the iterator, close's own error wins, else TypeError
  { async function* inner() { try { yield 1; } catch (e) { yield "caught:" + e; } } async function* g() { yield* inner(); } var it = g(); await it.next(); log.push("t7a " + J(await it.throw("boom"))); }
  { var t = []; var iter = { [Symbol.asyncIterator]() { return this; }, next() { return { value: 1, done: false }; }, return() { t.push("closed"); return {}; } }; async function* g() { try { yield* iter; } catch (e) { t.push(e.constructor.name); } } var it = g(); await it.next(); await it.throw("x"); log.push("t7b " + t.join()); }
  { var iter = { [Symbol.asyncIterator]() { return this; }, next() { return { value: 1, done: false }; }, return() { throw new RangeError("close-fails"); } }; async function* g() { try { yield* iter; } catch (e) { return e.name; } } var it = g(); await it.next(); log.push("t7c " + J(await it.throw("x"))); }
  // 8. invalid results and non-callable / rejecting methods
  { var iter = { [Symbol.asyncIterator]() { return this; }, next() { return 5; } }; async function* g() { yield* iter; } var it = g(); var e; try { await it.next(); } catch (err) { e = err.constructor.name; } log.push("t8a " + e); }
  { var iter = { [Symbol.asyncIterator]() { return this; }, next() { return { value: 1, done: false }; }, throw: 42 }; async function* g() { yield* iter; } var it = g(); await it.next(); var e; try { await it.throw("x"); } catch (err) { e = err.constructor.name; } log.push("t8b " + e); }
  { var iter = { [Symbol.asyncIterator]() { return this; }, next() { return Promise.reject(new SyntaxError("rejected-next")); } }; async function* g() { try { yield* iter; } catch (e) { return "caught " + e.name; } } var it = g(); log.push("t8c " + J(await it.next())); }
  { var iter = { [Symbol.asyncIterator]() { return this; }, next() { return { value: 1, done: false }; }, return() { return Promise.reject(new EvalError("rejected-return")); } }; async function* g() { try { yield* iter; } catch (e) { return "caught " + e.name; } } var it = g(); await it.next(); log.push("t8d " + J(await it.return("R"))); }
  // 9. mixed queued requests while the delegate's next() is pending; thenable values at await points
  { var order = []; var release; var iter = { [Symbol.asyncIterator]() { return this; }, calls: 0, next(v) { order.push("next(" + v + ")"); if (this.calls++ > 0) return Promise.resolve({ value: "later-" + v, done: false }); return new Promise(function (res) { release = function () { res({ value: { then: function (r) { order.push("value-then"); r("V"); } }, done: false }); }; }); }, return(v) { order.push("return(" + v + ")"); return { value: v, done: true }; } }; async function* g() { yield* iter; } var it = g(); var p1 = it.next("a").then(function (r) { order.push("p1:" + J(r)); }); var p2 = it.next("b").then(function (r) { order.push("p2:" + J(r)); }); var p3 = it.return("c").then(function (r) { order.push("p3:" + J(r)); }); await Promise.resolve(); order.push("release"); release(); await Promise.all([p1, p2, p3]); log.push("t9 " + order.join()); }
  // 10. forced collection while suspended in a delegation keeps the iterator, received value, and result
  { var iter = { [Symbol.asyncIterator]() { return this; }, i: 0, next(v) { this.i++; return { value: { big: new Array(1000).fill(this.i), sent: v }, done: this.i > 3 }; } }; async function* g() { var v = yield* iter; yield "end:" + v.big.length + "," + v.sent; } var it = g(); var a = await it.next(); gc(); var junk = []; for (var k = 0; k < 20000; k++) junk.push({ k: k }); junk = null; gc(); var b = await it.next("second"); gc(); var c = await it.next("third"); var d = await it.next("fourth"); log.push("t10 " + [a.value.big.length, b.value.sent, c.value.sent, d.value].join()); }
  console.log(log.join("\n"));
}
main();
