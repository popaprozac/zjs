// `with`: a name bound before the body (or outside the function, or
// nowhere) is looked up in the object first -- reads, writes, calls with
// the object as receiver, typeof, delete, var initializers, closures made
// in the body -- @@unscopables hides names, a read-modify-write resolves
// once, and a strict function inside sees a binding deleted meanwhile as
// gone. Node (V8) differs on the last two of those: it asks
// @@unscopables at each use rather than once a reference (5 6 4 where the
// specification, and test262's unscopables-inc-dec, have 3 9 5), and it
// does not throw for the deleted binding (test262's
// get-mutable-binding-binding-deleted-in-get-unscopables-strict-mode);
// those lines of the .expected are the specification's, set by hand.
var log = [];
var o = { a: 1, f() { return this === o; } };
var a = "global a", b = "global b";
with (o) {
  log.push(a, b, f());
  a = 2; b = "set b";
  var c = 3;
  log.push(typeof a, typeof zzz);
}
log.push(o.a, b, c, "c" in o);
function outer() {
  var x = "outer x", y = "outer y";
  var obj = { x: "obj x" };
  with (obj) {
    var g = function () { return x + "/" + y; };
    let inner = "block";
    obj.y = "obj y";
    log.push(g(), inner);
    x = "assigned";
    delete obj.y;
    log.push(g(), delete x, x);
  }
  return g;
}
const g = outer();
log.push(g());
var scoped = { valueOf: 1, join: 2 };
scoped[Symbol.unscopables] = Object.assign(Object.create(null), { join: true });
var join = "outer join";
with (scoped) { log.push(valueOf, join); }
try { with (null) {} } catch (e) { log.push(e.constructor.name); }
with ("str") { log.push(length, charAt(1)); }
for (var k in { p: 1 }) with ({ k: "shadow" }) log.push(k);
with ({ n: 0 }) { for (let i = 0; i < 3; i++) n += i; log.push(n); }
var calls = 0, flag = true, outerObj = { x: 7 }, innerObj;
with (outerObj) {
  with (innerObj = { x: 4, get [Symbol.unscopables]() { calls++; return { x: flag = !flag }; } }) { x++; x += 2; x ||= 9; }
}
log.push(calls, outerObj.x, innerObj.x);
var env = { binding: 0, get [Symbol.unscopables]() { delete env.binding; return null; } };
with (env) {
  try { (function () { "use strict"; return binding; })(); log.push("no throw"); } catch (e) { log.push(e.constructor.name); }
}
log.push(eval("1; with ({}) {}"), eval("2; with ({}) { 3; }"));
console.log(log.join("\n"));
