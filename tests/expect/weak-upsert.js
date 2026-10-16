// WeakMap upserts (getOrInsert, getOrInsertComputed): the proposal's
// semantics, with CanBeHeldWeakly applied on insertion. Node 25 does not
// ship these methods, so the expected output is written from the
// proposal text, not recorded: existing key -> its value, callback not
// called; absent key -> inserted value / computed value; a key that
// cannot be held weakly -> TypeError; a non-callable callback -> TypeError.
var r = [];
function t(f) { try { r.push(String(f())); } catch (e) { r.push(e.constructor.name); } }
var o = {}, s = Symbol("s"), reg = Symbol.for("reg");
t(function () { var w = new WeakMap(); return w.getOrInsert(o, 5) + "," + w.getOrInsert(o, 9) + "," + w.get(o); });
t(function () { new WeakMap().getOrInsert(reg, 1); });
t(function () { new WeakMap().getOrInsert(1, 1); });
t(function () { var w = new WeakMap(); var calls = 0; var a = w.getOrInsertComputed(o, function (k) { calls++; return k === o ? "computed" : "?"; }); var b = w.getOrInsertComputed(o, function () { calls++; return "again"; }); return a + "," + b + "," + calls; });
t(function () { new WeakMap().getOrInsertComputed(reg, function () { return 1; }); });
t(function () { new WeakMap().getOrInsertComputed(o, 5); });
t(function () { var w = new WeakMap(); w.getOrInsertComputed(s, function (k) { return typeof k; }); return w.get(s); });
console.log(r.join("|"));
