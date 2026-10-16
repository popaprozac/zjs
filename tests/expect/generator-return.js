// return() at a plain yield re-enters the generator: finally blocks run
// (one may yield again or return an override), an unstarted generator
// completes at once, a completed one answers done, throw() lands in the
// catch, and a for-of's iterator is closed on the way out.
var r = [];
function t(f) { try { r.push(String(f())); } catch (e) { r.push(e.constructor.name + ":" + e.message); } }
// return() at a plain yield runs finally blocks and completes with the value
t(function () { var log = []; function* g() { try { yield 1; } finally { log.push("f"); } } var it = g(); it.next(); var res = it.return("v"); return log.join() + "|" + res.value + "," + res.done + "|" + it.next().done; });
// a finally that yields keeps the generator alive after return()
t(function () { function* g() { try { yield 1; } finally { yield "in-finally"; } } var it = g(); it.next(); var a = it.return("v"); var b = it.next(); return a.value + "," + a.done + "|" + b.value + "," + b.done; });
// a finally that returns overrides the injected return value
t(function () { function* g() { try { yield 1; } finally { return "override"; } } var it = g(); it.next(); var res = it.return("v"); return res.value + "," + res.done; });
// return() before the body ran: completes at once, no finally
t(function () { var log = []; function* g() { try { yield 1; } finally { log.push("f"); } } var it = g(); var res = it.return("early"); return res.value + "," + res.done + "," + log.length; });
// return() on a completed generator
t(function () { function* g() { yield 1; } var it = g(); it.next(); it.next(); var res = it.return("late"); return res.value + "," + res.done; });
// nested try/finally on the way out, inner first
t(function () { var log = []; function* g() { try { try { yield 1; } finally { log.push("inner"); } } finally { log.push("outer"); } } var it = g(); it.next(); it.return(0); return log.join(); });
// throw() still lands in the catch
t(function () { function* g() { try { yield 1; } catch (e) { yield "caught " + e; } } var it = g(); it.next(); return it.throw("E").value; });
// return() while suspended inside a for-of closes the loop's iterator
t(function () { var closed = false; var iter = { [Symbol.iterator]() { return { next() { return { value: 1, done: false }; }, return() { closed = true; return {}; } }; } }; function* g() { for (var x of iter) { yield x; } } var it = g(); it.next(); it.return(); return closed; });
console.log(r.join("|"));
