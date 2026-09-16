// WeakMap / WeakSet: which values can be held weakly (objects and
// unregistered symbols, well-known symbols included; not Symbol.for
// symbols), what the methods return for a key that cannot be, upserts,
// constructor iterables, and behaviour across a forced collection with
// keys still held. Run with --expose-gc; node records with the same flag.
var r = [];
function t(f) { try { r.push(String(f())); } catch (e) { r.push(e.constructor.name); } }
var o = {}, s = Symbol("s"), reg = Symbol.for("reg");
t(function () { var w = new WeakMap(); w.set(o, 1); w.set(s, 2); w.set(Symbol.iterator, 3); return w.get(o) + w.get(s) + w.get(Symbol.iterator); });
t(function () { new WeakMap().set(reg, 1); });
t(function () { new WeakMap().set(1, 1); });
t(function () { new WeakMap().set("k", 1); });
t(function () { new WeakSet().add(reg); });
t(function () { new WeakSet().add(null); });
t(function () { var w = new WeakMap(); return [w.get(1), w.get(reg), w.has(1), w.has(reg), w.delete(1), w.delete(reg), w.get("x")].join(); });
t(function () { var w = new WeakSet(); return [w.has(1), w.has(reg), w.delete(reg), w.delete(undefined)].join(); });
t(function () { new WeakMap([[reg, 1]]); });
t(function () { new WeakMap([[1, 1]]); });
t(function () { new WeakSet([reg]); });
t(function () { var w = new WeakMap([[o, "a"], [s, "b"]]); return w.get(o) + w.get(s); });
t(function () { var w = new WeakSet([o, s, Symbol.asyncIterator]); return [w.has(o), w.has(s), w.has(Symbol.asyncIterator)].join(); });
t(function () { new WeakMap([1]); });
t(function () { var w = new WeakMap(); var held = {}; w.set(held, { deep: [1, 2, 3] }); for (var i = 0; i < 1000; i++) w.set({}, i); gc(); gc(); return w.has(held) + "," + w.get(held).deep.length; });
t(function () { var w = new WeakSet(); var held = {}; w.add(held); for (var i = 0; i < 1000; i++) w.add({}); gc(); return w.has(held); });
t(function () { var w = new WeakMap(); var k = {}; var v = { via: k }; w.set(k, v); var direct = v; k = null; gc(); return typeof direct.via; });
t(function () { var w = new WeakMap(); var k = {}; var w2 = new WeakMap(); w.set(k, w2); w2.set(k, "inner"); gc(); return w.get(k).get(k); });
t(function () { var a = new WeakMap(), b = new WeakMap(); var k1 = {}, k2 = {}; a.set(k1, { next: k2 }); b.set(k2, "end"); var keep = k1; k2 = null; gc(); return b.get(a.get(keep).next); });
t(function () { var w = new WeakMap(); var k = {}; w.set(k, 1); w.delete(k); w.set(k, 2); gc(); return w.get(k); });
t(function () { var w = new WeakMap(); w.set(o, 1); return w.set(o, 2) === w; });
t(function () { var w = new WeakSet(); return w.add(o) === w; });
t(function () { return Object.prototype.toString.call(new WeakMap()) + Object.prototype.toString.call(new WeakSet()); });
console.log(r.join("|"));
