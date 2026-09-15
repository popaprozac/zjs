var log = [];
var m = new Map([["a", 1], ["b", 2]]);
m.set("c", 3).set("a", 10);
var keyObj = {};
m.set(keyObj, "obj").set(NaN, "nan").set(-0, "zero").set(1, "one").set("1", "string one");
log.push(m.size, m.get("a"), m.get("b"), m.get(keyObj), m.get(NaN), m.get(0), m.get(-0), m.get(1), m.get("1"), m.get("missing"), m.has("c"), m.has({}), m.delete("b"), m.delete("b"), m.size);
var order = [];
m.forEach(function (v, k) { order.push(typeof k === "object" ? "obj" : String(k)); });
log.push(order.join(), [...m.keys()].length, [...m.values()].join(), [...m.entries()][0].join(":"), [...m][1].join(":"), Object.prototype.toString.call(m));
var during = [];
var live = new Map([[1, "x"]]);
for (var [k, v] of live) { during.push(k); if (k === 1) { live.set(2, "y"); live.delete(1); } if (k === 2) live.set(3, "z"); }
log.push(during.join());
m.clear();
log.push(m.size, m.get("a"), [...m].length);
var s = new Set([3, 1, 3, "3", NaN, NaN]);
s.add(2).add(1);
log.push(s.size, s.has(3), s.has("3"), s.has(NaN), s.has(4), [...s].join(), [...s.entries()][0].join(":"), [...s.keys()].join(), s.delete(3), s.has(3), s.size);
var seen = [];
s.forEach(function (v, v2, set) { seen.push(v === v2 && set === s); });
log.push(seen.join());
var big = new Map();
for (var i = 0; i < 1000; i++) big.set("k" + i, i);
var sum = 0;
for (var j = 0; j < 1000; j += 7) sum += big.get("k" + j);
for (var d = 0; d < 1000; d += 2) big.delete("k" + d);
log.push(big.size, sum, big.get("k7"), big.get("k8"), big.has("k999"));
var wm = new WeakMap();
var wk = {};
wm.set(wk, "weak");
var ws = new WeakSet([wk]);
log.push(wm.get(wk), wm.has(wk), wm.has({}), wm.delete(wk), wm.has(wk), ws.has(wk), ws.has({}), Object.prototype.toString.call(wm), typeof wm.size);
var errors = [];
try { new Map([1]); } catch (e) { errors.push(e.name); }
try { wm.set(1, 2); } catch (e) { errors.push(e.name); }
try { Map.prototype.get.call({}, 1); } catch (e) { errors.push(e.name); }
try { new Set(5); } catch (e) { errors.push(e.name); }
log.push(errors.join(), Map.length, Set.name, typeof Object.getOwnPropertyDescriptor(Map.prototype, "size").get, m instanceof Map, new Set() instanceof Set);
var a = new Set([1, 2, 3, 4]);
var b = new Set([3, 4, 5]);
log.push([...a.union(b)].join(), [...a.intersection(b)].join(), [...a.difference(b)].join(), [...b.difference(a)].join(), [...a.symmetricDifference(b)].join(), a.isSubsetOf(b), new Set([3]).isSubsetOf(b), a.isSupersetOf(new Set([1, 4])), a.isDisjointFrom(b), a.isDisjointFrom(new Set([9])), a.union(b) instanceof Set, a.size);
var setLike = { size: 2, has: function (v) { return v === 2 || v === 9; }, keys: function () { return [2, 9][Symbol.iterator](); } };
log.push([...a.intersection(setLike)].join(), [...a.union(setLike)].join(), a.isDisjointFrom(setLike));
var setErrors = [];
try { a.union(1); } catch (e) { setErrors.push(e.name); }
try { a.union({ size: NaN, has: function () {}, keys: function () {} }); } catch (e) { setErrors.push(e.name); }
try { a.union({ size: -1, has: function () {}, keys: function () {} }); } catch (e) { setErrors.push(e.name); }
try { a.union({ size: 1, has: 1, keys: function () {} }); } catch (e) { setErrors.push(e.name); }
log.push(setErrors.join());
var grouped = Map.groupBy([1, 2, 3, 4, 5, 6], function (n) { return n % 3; });
log.push(grouped.size, grouped.get(0).join(), grouped.get(1).join(), grouped.get(2).join());
var og = Object.groupBy(["apple", "avocado", "banana"], function (s) { return s[0]; });
log.push(Object.keys(og).join(), og.a.join(), og.b.join(), Object.getPrototypeOf(og));
var up = new Map();
log.push(up.getOrInsert("k", 1), up.getOrInsert("k", 2), up.getOrInsertComputed("j", function (k) { return k + "!"; }), up.getOrInsertComputed("j", function () { return "no"; }), up.size);
log.push(Map[Symbol.species] === Map, Set[Symbol.species] === Set, Array[Symbol.species] === Array);
log.join("|");
