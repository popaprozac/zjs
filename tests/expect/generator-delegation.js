// Synchronous yield* delegation: next(v) / throw(e) / return(v) forwarded
// to the delegate, its result objects passed through unchanged, its final
// value the expression's, finally blocks on the way out, delegates without
// throw or return, and delegation to arrays, strings, and Map iterators.
var r = [];
function t(f) { try { r.push(String(f())); } catch (e) { r.push(e.constructor.name + ":" + e.message); } }
function* inner() { var a = yield 1; var b = yield a + 10; return "ret:" + b; }
// next(value) forwarded to the delegate; the delegate's return value is the expression's
t(function () { function* outer() { var v = yield* inner(); yield v; } var g = outer(); return [g.next().value, g.next(5).value, g.next(7).value, g.next().done].join(); });
// delegating to an array and a string
t(function () { function* g() { var v = yield* [1, 2]; yield* "ab"; return v; } var it = g(); return [it.next().value, it.next().value, it.next().value, it.next().value, it.next().value, it.next().done].join(); });
// result objects pass through unchanged
t(function () { var res = { value: 42, done: false, extra: 1 }; var iter = { [Symbol.iterator]() { return this; }, next() { return res; } }; function* g() { yield* iter; } var got = g().next(); return (got === res) + "," + got.extra; });
// return() forwarded: inner finally runs, outer continues per the delegate's answer
t(function () { var log = []; function* inner2() { try { yield 1; yield 2; } finally { log.push("inner-finally"); } } function* outer() { try { yield* inner2(); } finally { log.push("outer-finally"); } } var g = outer(); g.next(); var res = g.return("R"); return log.join("+") + "|" + res.value + "|" + res.done; });
// return() on a delegate whose return keeps going
t(function () { var iter = { [Symbol.iterator]() { return this; }, next() { return { value: "n", done: false }; }, return(v) { return { value: "still-" + v, done: false }; } }; function* g() { yield* iter; } var it = g(); it.next(); var res = it.return("x"); return res.value + "," + res.done + "," + it.next().value; });
// return() on a delegate without a return method: outer returns the value
t(function () { var iter = { [Symbol.iterator]() { return this; }, next() { return { value: 1, done: false }; } }; var log = []; function* g() { try { yield* iter; } finally { log.push("fin"); } } var it = g(); it.next(); var res = it.return("gone"); return res.value + "," + res.done + "," + log.join(); });
// throw() forwarded: the delegate catches it and continues
t(function () { function* inner3() { try { yield 1; } catch (e) { yield "caught:" + e; } } function* g() { var v = yield* inner3(); return v; } var it = g(); it.next(); return it.throw("boom").value; });
// throw() with no throw method: the delegate is closed and a TypeError raised in the outer generator
t(function () { var closed = false; var iter = { [Symbol.iterator]() { return this; }, next() { return { value: 1, done: false }; }, return() { closed = true; return {}; } }; function* g() { try { yield* iter; } catch (e) { return e.constructor.name + "," + closed; } } var it = g(); it.next(); return it.throw("x").value; });
// the delegate's exception propagates through the outer generator
t(function () { function* inner4() { yield 1; throw new RangeError("inner"); } function* g() { yield* inner4(); } var it = g(); it.next(); it.next(); });
// done getter observed once per step, value read once
t(function () { var reads = 0; var iter = { [Symbol.iterator]() { return this; }, next() { return { get done() { reads++; return reads > 3; }, value: "v" }; } }; function* g() { yield* iter; } var it = g(); it.next(); it.next(); it.next(); return reads; });
// nested delegation forwards next(value) two levels
t(function () { function* a() { var x = yield "a1"; return "a-got-" + x; } function* b() { var y = yield* a(); yield y; } function* c() { yield* b(); } var it = c(); it.next(); return it.next("Z").value; });
// generator delegating to a Map iterator, spread of a delegating generator
t(function () { function* g() { yield* new Map([[1, "a"], [2, "b"]]).keys(); } return [...g()].join(); });
// return value of yield* when the delegate completes on the first call
t(function () { function* e() { return "immediate"; } function* g() { var v = yield* e(); yield v; } return g().next().value; });
// throw() when the delegate's throw completes it: the value becomes the expression's
t(function () { var iter = { [Symbol.iterator]() { return this; }, next() { return { value: 1, done: false }; }, throw(e) { return { value: "handled-" + e, done: true }; } }; function* g() { var v = yield* iter; yield "after:" + v; } var it = g(); it.next(); return it.throw("E").value; });
console.log(r.join("|"));
