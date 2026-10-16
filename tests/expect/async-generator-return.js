// Async generator return and cleanup, as event traces: return before the
// first next (value awaited, no finally), during suspension (finally runs,
// value awaited), after completion (awaited, or the rejection); finally
// blocks that await, yield, throw, or return an override; a rejected
// return value thrown into the body; queued next/return/throw settling
// in order, each once; a thenable return value; a return queued behind
// an await.
// Async generator return / cleanup, as node-recorded event traces.
var log = [];
function show(tag, r) { return tag + "=" + (r && typeof r === "object" ? JSON.stringify(r) : String(r)); }
async function main() {
  // 1. return before first next: value awaited, finally not run
  { var ran = false; async function* g() { try { yield 1; } finally { ran = true; } } var it = g(); var r = await it.return(Promise.resolve("early")); log.push("t1 " + show("r", r) + " ran=" + ran + " next=" + JSON.stringify(await it.next())); }
  // 2. return during suspension: finally runs, value awaited
  { var t = []; async function* g() { try { yield 1; } finally { t.push("finally"); } } var it = g(); await it.next(); var r = await it.return(Promise.resolve("v")); log.push("t2 " + t.join() + " " + show("r", r)); }
  // 3. return after completion: awaited value, or rejection
  { async function* g() { yield 1; } var it = g(); await it.next(); await it.next(); var r = await it.return(Promise.resolve("late")); var rej; try { await it.return(Promise.reject(new Error("no"))); } catch (e) { rej = e.message; } log.push("t3 " + show("r", r) + " rej=" + rej); }
  // 4. finally with await, yield, throw, and an overriding return
  { var t = []; async function* g() { try { yield 1; } finally { await Promise.resolve(); t.push("awaited"); yield "fin-yield"; t.push("after-yield"); } } var it = g(); await it.next(); var a = await it.return("R"); var b = await it.next(); log.push("t4a " + t.join() + " " + show("a", a) + " " + show("b", b)); }
  { async function* g() { try { yield 1; } finally { throw new RangeError("fin-throw"); } } var it = g(); await it.next(); var e; try { await it.return("R"); } catch (err) { e = err.name; } log.push("t4b " + e + " " + JSON.stringify(await it.next())); }
  { async function* g() { try { yield 1; } finally { return "override"; } } var it = g(); await it.next(); log.push("t4c " + show("r", await it.return("R"))); }
  // 5. rejected return value during suspension: thrown into the body at the yield
  { var t = []; async function* g() { try { yield 1; } catch (e) { t.push("caught " + e); yield "recovered"; } } var it = g(); await it.next(); var r = await it.return(Promise.reject("boom")); log.push("t5 " + t.join() + " " + show("r", r)); }
  // 6. queued next/return/throw settle FIFO, each once
  { var t = []; async function* g() { try { var x = yield "a"; t.push("got " + x); yield "b"; } finally { t.push("cleanup"); } } var it = g(); var ps = [it.next("first"), it.next("second"), it.return("R"), it.next("ignored"), it.throw("late-throw")]; var results = []; for (var i = 0; i < ps.length; i++) { try { results.push(JSON.stringify(await ps[i])); } catch (e) { results.push("throw:" + e); } } log.push("t6 " + t.join() + " | " + results.join(" ")); }
  // 7. return whose value is a thenable, settlement order with a pending next
  { var order = []; async function* g() { yield 1; yield 2; } var it = g(); var p1 = it.next().then(function (r) { order.push("n1:" + r.value); }); var p2 = it.return({ then: function (res) { order.push("then-called"); res("T"); } }).then(function (r) { order.push("ret:" + r.value + "," + r.done); }); var p3 = it.next().then(function (r) { order.push("n3:" + r.done); }); await Promise.all([p1, p2, p3]); log.push("t7 " + order.join()); }
  // 8. return on a generator awaiting inside its body (queued until the await settles)
  { var t = []; var resolveIt; async function* g() { try { t.push("body"); await new Promise(function (r) { resolveIt = r; }); t.push("after-await"); yield 1; } finally { t.push("fin"); } } var it = g(); var p = it.next(); var q = it.return("R"); await Promise.resolve(); t.push("resolving"); resolveIt(); var a = await p; var b = await q; log.push("t8 " + t.join() + " " + show("a", a) + " " + show("b", b)); }
  console.log(log.join("\n"));
}
main();
