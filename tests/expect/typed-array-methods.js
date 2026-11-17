// %TypedArray%.prototype's methods and %TypedArray%.from and .of: each
// method's result, the internal length over a `length` property, species,
// a buffer detached by a callback or a conversion, and the same buffer as
// source and target.
function show(label, value) {
  console.log(label, Array.isArray(value) ? JSON.stringify(value) : String(value));
}
function list(ta) { return Array.prototype.slice.call(ta); }
function thrown(f) {
  try { f(); return "no throw"; } catch (e) { return e.constructor.name; }
}
function signed(values) {
  return values.map(function (v) { return Object.is(v, -0) ? "-0" : v !== v ? "NaN" : v; });
}

// Callbacks.
var numbers = new Int16Array([5, -3, 8, 0, 12]);
var seen = [];
numbers.forEach(function (v, i, a) { seen.push(v + "@" + i + (a === numbers ? "" : "?")); });
show("forEach", seen);
show("every some", [numbers.every(function (v) { return v < 20; }), numbers.every(function (v) { return v > 0; }), numbers.some(function (v) { return v < 0; }), numbers.some(function (v) { return v > 99; })]);
show("finds", [numbers.find(function (v) { return v > 6; }), numbers.findIndex(function (v) { return v > 6; }), numbers.findLast(function (v) { return v > 6; }), numbers.findLastIndex(function (v) { return v > 6; }), numbers.find(function () { return false; }), numbers.findIndex(function () { return false; })]);
var doubled = numbers.map(function (v) { return v * 2; });
show("map", [list(doubled), doubled.constructor.name, doubled !== numbers]);
show("map wraps", list(new Uint8Array([200, 100]).map(function (v) { return v * 2; })));
var positive = numbers.filter(function (v) { return v > 0; });
show("filter", [list(positive), positive.constructor.name, positive.length]);
show("this arg", new Int8Array([1]).map(function () { return this.k; }, { k: 7 })[0]);
show("reduce", [numbers.reduce(function (a, v) { return a + v; }), numbers.reduceRight(function (a, v) { return a + "," + v; }, ""), new Float64Array([2]).reduce(function () { return 9; }), thrown(function () { new Int8Array(0).reduce(function () {}); })]);
show("reduceRight bare", new Int8Array([1, 2, 3]).reduceRight(function (a, v) { return a + "" + v; }));
show("reduce object", new Uint8Array([1, 2]).reduce(function (a, v) { a.push(v); return a; }, []).join("+"));
show("not callable", [thrown(function () { numbers.map(); }), thrown(function () { numbers.forEach(3); }), thrown(function () { numbers.filter({}); })]);

// Search.
var floats = new Float32Array([1.5, NaN, -0, 2, 1.5]);
show("indexOf", [floats.indexOf(1.5), floats.indexOf(1.5, 1), floats.indexOf(NaN), floats.indexOf(0), floats.indexOf(2, -2), floats.indexOf(1.5, 99), floats.indexOf("2")]);
show("lastIndexOf", [floats.lastIndexOf(1.5), floats.lastIndexOf(1.5, 3), floats.lastIndexOf(1.5, -2), floats.lastIndexOf(0), floats.lastIndexOf(9)]);
show("includes", [floats.includes(NaN), floats.includes(0), floats.includes(2, 4), floats.includes(1.5, -1), new Int8Array(0).includes(undefined)]);
show("at", [floats.at(0), floats.at(-1), floats.at(5), floats.at(-6), floats.at("3")]);

// Strings.
show("join", [new Int8Array([1, -2, 3]).join(), new Int8Array([1, -2, 3]).join(" | "), new Int8Array(0).join(), new Float64Array([0.5, -0, NaN]).join(undefined)]);
show("toLocaleString", new Uint8Array([1, 2, 3]).toLocaleString());
show("toString", [new Int8Array([4, 5]).toString(), Int8Array.prototype.toString === Array.prototype.toString, String(new Uint16Array([7]))]);

// Sorting.
show("sort default", signed(list(new Float64Array([3, NaN, -0, 0, -Infinity, 1, -1, NaN, 0, -0]).sort())));
show("sort ints", list(new Int32Array([10, 9, 1000, -5, 2]).sort()));
show("sort comparator", list(new Uint8Array([1, 2, 3, 4, 5]).sort(function (a, b) { return b - a; })));
var pairs = new Uint16Array([21, 12, 31, 11, 22]);
show("sort stable", list(pairs.sort(function (a, b) { return (a % 10) - (b % 10); })));
show("sort errors", [thrown(function () { pairs.sort(1); }), thrown(function () { pairs.sort(function () { throw new RangeError("x"); }); })]);
var unsorted = new Int8Array([3, 1, 2]);
var sorted = unsorted.toSorted();
show("toSorted", [list(sorted), list(unsorted), sorted.constructor.name, list(unsorted.toSorted(function (a, b) { return b - a; }))]);

// Copies and edits.
show("reverse", [list(new Int8Array([1, 2, 3, 4]).reverse()), list(new Int8Array([1, 2, 3]).reverse()), list(new Int8Array(0).reverse())]);
var forward = new Int8Array([1, 2, 3]);
show("toReversed", [list(forward.toReversed()), list(forward)]);
show("with", [list(forward.with(1, 9)), list(forward.with(-1, 7)), list(forward), thrown(function () { forward.with(3, 1); }), thrown(function () { forward.with(-4, 1); }), list(new Uint8Array([1]).with(0, 300))]);
show("fill", [list(new Int8Array(4).fill(7)), list(new Int8Array(4).fill(7, 1, -1)), list(new Uint8Array(3).fill(-1)), list(new Float32Array(2).fill("1.5"))]);
show("copyWithin", [list(new Int8Array([1, 2, 3, 4, 5]).copyWithin(0, 3)), list(new Int8Array([1, 2, 3, 4, 5]).copyWithin(1, 0, 3)), list(new Int8Array([1, 2, 3, 4, 5]).copyWithin(-2, 0)), list(new Int16Array([1, 2, 3, 4]).copyWithin(2, 0))]);
var wide = new Float64Array([1.5, 2.5, 3.5, 4.5]);
show("slice", [list(wide.slice(1, 3)), list(wide.slice(-1)), list(wide.slice(3, 1)), wide.slice().constructor.name, wide.slice() !== wide]);
var whole = new Int8Array([1, 2, 3, 4, 5, 6]);
var middle = whole.subarray(2, 5);
middle[0] = 30;
show("subarray", [list(middle), whole[2], middle.byteOffset, middle.buffer === whole.buffer, list(whole.subarray(-2)), whole.subarray(4, 1).length, new Int16Array(4).subarray(1).byteOffset]);

// set.
var target = new Int16Array(6);
target.set([1, 2, 3]);
target.set(new Int8Array([-1, -2]), 4);
target.set({ length: 1, 0: "7" }, 3);
show("set", [list(target), thrown(function () { target.set([1, 2], 5); }), thrown(function () { target.set([1], -1); }), thrown(function () { target.set(new Int8Array(7)); }), target.set([])]);
var sixteen = new Int16Array(4);
sixteen.set(new Int16Array([300, -2]), 1);
show("set same kind", list(sixteen));
var shared = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
shared.set(shared.subarray(0, 4), 2);
show("set overlap", list(shared));
var bytes = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
var halves = new Uint16Array(bytes.buffer, 0, 2);
bytes.set(halves, 4);
show("set overlap kinds", list(bytes));
var nanBits = new Float64Array([NaN]);
var copied = new Float64Array(1);
copied.set(nanBits);
show("set NaN", copied[0] !== copied[0]);
var converted = new Uint8Array(3);
converted.set(new Float64Array([1.7, -1, 300]));
show("set converted", list(converted));

// The internal length, not a `length` property.
var shadowed = new Int8Array([1, 2, 3]);
Object.defineProperty(shadowed, "length", { value: 1 });
show("internal length", [shadowed.join(), shadowed.map(function (v) { return v; }).length, shadowed.indexOf(3), shadowed.slice().length]);

// Species.
class Doubling extends Int16Array {
  static get [Symbol.species]() { return Float64Array; }
}
var special = new Doubling([1, 2, 3]);
show("species", [special.map(function (v) { return v / 2; }).constructor.name, list(special.map(function (v) { return v / 2; })), special.filter(function () { return true; }).constructor.name, special.slice(1).constructor.name, thrown(function () { special.subarray(1); })]);
var plain = new Int16Array([1, 2]);
plain.constructor = undefined;
show("species default", plain.map(function (v) { return v; }).constructor.name);
class Own extends Uint8Array {}
show("subclass result", [new Own([1, 2]).map(function (v) { return v; }) instanceof Own, new Own([1, 2]).toReversed() instanceof Own, new Own([3]).toSorted().constructor.name]);
class Short extends Uint8Array {
  static get [Symbol.species]() { return function () { return new Uint8Array(1); }; }
}
show("species too short", thrown(function () { new Short([1, 2, 3]).map(function (v) { return v; }); }));
class NotTyped extends Uint8Array {
  static get [Symbol.species]() { return function () { return {}; }; }
}
show("species not typed", thrown(function () { new NotTyped([1]).slice(); }));

// A buffer detached during the walk.
function detachedDuring(run) {
  var buffer = new ArrayBuffer(4);
  var ta = new Uint8Array(buffer);
  ta.set([1, 2, 3, 4]);
  var log = [];
  var result = run(ta, function () { if (!buffer.detached) buffer.transfer(); }, log);
  return [JSON.stringify(log), String(result)];
}
show("detach forEach", detachedDuring(function (ta, detach, log) { ta.forEach(function (v, i) { if (i === 1) detach(); log.push(v); }); }));
show("detach map", detachedDuring(function (ta, detach, log) { return thrown(function () { ta.map(function (v, i) { if (i === 0) detach(); log.push(v); return v; }); }); }));
show("detach includes", detachedDuring(function (ta, detach) { return ta.includes(undefined, { valueOf: function () { detach(); return 0; } }); }));
show("detach indexOf", detachedDuring(function (ta, detach) { return ta.indexOf(undefined, { valueOf: function () { detach(); return 0; } }); }));
show("detach join", detachedDuring(function (ta, detach) { return ta.join({ toString: function () { detach(); return "-"; } }); }));
show("detach fill", detachedDuring(function (ta, detach) { return thrown(function () { ta.fill({ valueOf: function () { detach(); return 1; } }); }); }));
show("detach sort", detachedDuring(function (ta, detach) { return ta.sort(function (a, b) { detach(); return a - b; }).length; }));
show("detach copyWithin", detachedDuring(function (ta, detach) { return thrown(function () { ta.copyWithin(0, { valueOf: function () { detach(); return 1; } }); }); }));
show("detached receiver", [thrown(function () { var t = new Int8Array(2); t.buffer.transfer(); t.map(function () {}); }), thrown(function () { var t = new Int8Array(2); t.buffer.transfer(); t.subarray(0); })]);
show("not typed", [thrown(function () { Int8Array.prototype.join.call([1]); }), thrown(function () { Int8Array.prototype.at.call({ length: 1, 0: 1 }, 0); })]);

// from and of.
show("from", [list(Int8Array.from([1, 2, 3])), list(Uint8Array.from({ length: 2, 0: 9 })), list(Int16Array.from(new Set([4, 5]))), list(Float32Array.from("12")), list(Int8Array.from([1, 2], function (v, i) { return v * 10 + i + this.k; }, { k: 0.5 }))]);
show("of", [list(Int8Array.of(1, 2, 300)), Uint8Array.of().length, list(Float64Array.of("1.5", true))]);
show("from of errors", [thrown(function () { Int8Array.from.call({}, []); }), thrown(function () { Int8Array.of.call(function () { return {}; }, 1); }), thrown(function () { Int8Array.from([], 5); }), thrown(function () { Int8Array.from(null); })]);
show("from subclass", [Own.from([1]) instanceof Own, Own.of(1, 2).length]);
show("lengths", [Int8Array.prototype.map.length, Int8Array.prototype.slice.length, Int8Array.prototype.subarray.length, Int8Array.prototype.with.length, Int8Array.prototype.reverse.length, Int8Array.from.length, Int8Array.of.length]);
