// Object.keys, values, entries, and getOwnPropertyNames, Object.assign,
// object spread and rest, and for-in list or copy a plain object's
// properties straight from its slots. The order must be the language's,
// and each property must be looked at when it is reached: a getter, or
// a setter on the object being assigned to, may change what follows.
var log = [];
function note() { var parts = []; for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i])); log.push(parts.join(" ")); }
function caught(run) { try { return run(); } catch (error) { return error.constructor.name; } }
function pairs(object) { return Object.entries(object).map(function (pair) { return pair[0] + "=" + String(pair[1]); }).join(); }
function forIn(object) { var names = []; for (var name in object) names.push(name); return names.join(); }
function described(object) {
  return Reflect.ownKeys(object).map(function (key) {
    var found = Object.getOwnPropertyDescriptor(object, key);
    return String(key) + ":" + ("value" in found ? String(found.value) : "accessor") + (found.enumerable ? "" : "!e") + (found.writable === false ? "!w" : "") + (found.configurable ? "" : "!c");
  }).join();
}
function every(object) {
  return [Object.keys(object).join(), Object.values(object).join(), pairs(object), Object.getOwnPropertyNames(object).join(), forIn(object), described(Object.assign({}, object)), described({ ...object })].join(" | ");
}

// --- plain objects, and the order of their names ---
var record = { id: 1, name: "n", kind: "k", size: 4, tags: null, open: true, left: 7, top: undefined };
note("a record:", every(record));
note("empty:", "[" + every({}) + "]", Object.keys({}).length, Object.entries({}).length);
note("results:", Array.isArray(Object.keys(record)), Object.keys(record) === Object.keys(record), Array.isArray(Object.entries(record)[0]), Object.entries(record)[0].length, Object.values(record).length);
var ordered = { b: 1, 2: "two", a: 2, 1: "one", 10: "ten", "01": "not an index", "-1": "nor this", 4294967294: "the last index", 4294967295: "past it", c: 3 };
note("index names first:", every(ordered));
var late = { z: 1 };
late[5] = "five"; late.y = 2; late[0] = "zero"; late[3] = "three";
note("added in another order:", every(late));
var one = {}; one[7] = "seven";
note("one index name:", every(one));

// --- what is not listed ---
var marked = Symbol("marked"), other = Symbol("other");
var mixed = { a: 1, [marked]: "symbol", b: 2 };
Object.defineProperty(mixed, "hidden", { value: "not enumerable", enumerable: false, writable: true, configurable: true });
mixed.c = 3;
mixed[other] = "second symbol";
Object.defineProperty(mixed, "fixed", { value: "read-only", enumerable: true, writable: false, configurable: false });
note("symbols and a hidden one:", every(mixed));
note("its symbols:", Object.getOwnPropertySymbols(mixed).map(String).join(), Reflect.ownKeys(mixed).map(String).join());
Object.defineProperty(mixed, "a", { enumerable: false });
note("made not enumerable:", every(mixed));
Object.defineProperty(mixed, "a", { enumerable: true });
note("and enumerable again:", Object.keys(mixed).join(), forIn(mixed));
var onlySymbols = { [marked]: 1 };
note("only a symbol:", "[" + Object.keys(onlySymbols).join() + "]", described(Object.assign({}, onlySymbols)), described({ ...onlySymbols }));

// --- deleted, re-added, and many ---
var loose = { a: 1, b: 2, c: 3, d: 4 };
delete loose.b;
note("one deleted:", every(loose));
loose.b = "back";
note("and added again:", every(loose));
delete loose.b;
note("the newest deleted:", every(loose));
delete loose.a; delete loose.c; delete loose.d;
note("all deleted:", "[" + every(loose) + "]");
loose.fresh = 1;
note("and one new:", every(loose));
var wide = {};
for (var w = 0; w < 80; w++) wide["k" + w] = w;
note("eighty:", Object.keys(wide).length, Object.keys(wide)[0], Object.keys(wide)[79], Object.values(wide)[79], Object.entries(wide)[40].join("="), forIn(wide).length, Object.keys(Object.assign({}, wide)).length, Object.keys({ ...wide }).join() === Object.keys(wide).join());
wide[3] = "index"; delete wide.k0; wide.k0 = "again";
note("eighty, changed:", Object.keys(wide)[0], Object.keys(wide)[1], Object.keys(wide)[80], Object.values({ ...wide })[80], forIn(wide).split(",")[0], Object.getOwnPropertyNames(wide).length);

// --- accessors, which may change what follows ---
var reads = [];
var watched = { a: 1, get b() { reads.push("b"); return 2; }, c: 3 };
note("an accessor:", every(watched), reads.join());
function changing(change) {
  var object = { first: 1, get second() { change(object); return 2; }, third: 3, fourth: 4 };
  return object;
}
function changes(name, change) {
  var results = [
    Object.values(changing(change)).join(),
    pairs(changing(change)),
    described(Object.assign({}, changing(change))),
    described({ ...changing(change) }),
    (function () { var { first, ...rest } = changing(change); return described(rest); })()
  ];
  note(name, results.join(" | "));
}
changes("a getter that deletes a later one:", function (o) { delete o.third; });
changes("that deletes the last:", function (o) { delete o.fourth; });
changes("that deletes and adds it again:", function (o) { delete o.fourth; o.fourth = "again"; });
changes("that deletes the last and adds another:", function (o) { delete o.fourth; o.fifth = 5; });
changes("that adds one:", function (o) { o.fifth = 5; });
changes("that hides a later one:", function (o) { Object.defineProperty(o, "third", { enumerable: false }); });
changes("that rewrites a later one:", function (o) { o.third = "rewritten"; });
changes("that makes a later one a getter:", function (o) { Object.defineProperty(o, "fourth", { get: function () { return "got"; }, enumerable: true, configurable: true }); });
changes("that deletes an earlier one:", function (o) { delete o.first; });
changes("that adds many:", function (o) { for (var n = 0; n < 70; n++) o["more" + n] = n; });
changes("that freezes:", function (o) { Object.freeze(o); });
changes("that lists the same object:", function (o) { delete o.third; reads.push(Object.keys(o).join("/")); });
note("lists made inside a getter:", reads.slice(-3).join(" "));
var crowded = {};
for (var c = 0; c < 80; c++) crowded["c" + c] = c;
Object.defineProperty(crowded, "c1", { get: function () { for (var d = 2; d < 70; d++) delete crowded["c" + d]; for (var a = 0; a < 40; a++) crowded["added" + a] = "new"; return "got"; }, enumerable: true, configurable: true });
note("a getter in a crowded object that deletes and adds:", Object.values(crowded).join());
crowded = {};
for (c = 0; c < 80; c++) crowded["c" + c] = c;
Object.defineProperty(crowded, "c1", { get: function () { for (var d = 2; d < 70; d++) delete crowded["c" + d]; for (var a = 0; a < 40; a++) crowded["added" + a] = "new"; return "got"; }, enumerable: true, configurable: true });
note("the same, spread and assigned:", Object.values({ ...crowded }).join(), Object.keys(crowded).length);
crowded = {};
for (c = 0; c < 80; c++) crowded["c" + c] = c;
Object.defineProperty(crowded, "c1", { get: function () { for (var d = 2; d < 70; d++) delete crowded["c" + d]; for (var a = 0; a < 40; a++) crowded["added" + a] = "new"; return "got"; }, enumerable: true, configurable: true });
note("and assigned:", Object.values(Object.assign({}, crowded)).join(), pairs(crowded).length);
note("a getter that throws:", caught(function () { return Object.values({ a: 1, get b() { throw new RangeError("no"); } }); }), caught(function () { return Object.assign({}, { get b() { throw new RangeError("no"); } }); }), caught(function () { return { ...{ get b() { throw new RangeError("no"); } } }; }));
var walks = { a: 1, get b() { return Object.keys(record).length + Object.values(small()).length + JSON.stringify({ x: 1 }).length; }, c: 3 };
function small() { return { p: 1, get q() { return Object.keys(walks).length; } }; }
note("walks inside a walk:", Object.values(walks).join(), pairs(walks), Object.values(walks).join());

// --- Object.assign: a setter on the target may change the source ---
function assigning(change) {
  var source = { first: 1, second: 2, third: 3, fourth: 4 };
  var target = { set second(value) { this.got = value; change(source); } };
  Object.assign(target, source);
  return described(target);
}
note("a setter that deletes a later one:", assigning(function (s) { delete s.third; }));
note("that deletes the last and adds another:", assigning(function (s) { delete s.fourth; s.fifth = 5; }));
note("that deletes and adds it again:", assigning(function (s) { delete s.fourth; s.fourth = "again"; }));
note("that hides a later one:", assigning(function (s) { Object.defineProperty(s, "fourth", { enumerable: false }); }));
note("that rewrites a later one:", assigning(function (s) { s.third = "rewritten"; }));
note("that adds many:", assigning(function (s) { for (var n = 0; n < 70; n++) s["more" + n] = n; }));
var chained = Object.assign({ kept: 0 }, { a: 1 }, null, { b: 2, a: "later" }, undefined, { c: 3 });
note("several sources:", described(chained));
var self = { a: 1, b: 2 };
note("onto itself:", Object.assign(self, self) === self, described(self));
var locked = Object.freeze({ a: 0 });
note("a frozen target:", caught(function () { return Object.assign(locked, { z: 1 }); }), caught(function () { return Object.assign(locked, {}); }) === locked);
var partly = { a: 0 };
Object.defineProperty(partly, "b", { value: "fixed", writable: false, enumerable: true });
note("one read-only name:", caught(function () { return Object.assign(partly, { a: 1, b: 2, c: 3 }); }), described(partly));
note("a setter that throws:", caught(function () { return Object.assign({ set a(v) { throw new RangeError("no"); } }, { a: 1 }); }));
var inherited = Object.create({ set viaProto(value) { this.seen = "setter ran with " + value; } });
note("a setter on the target's prototype:", described(Object.assign(inherited, { viaProto: 5, own: 6 })));
note("other sources:", described(Object.assign({}, "ab", [7, 8], 5, true, function f() {})), described(Object.assign({}, Object.assign(function g() {}, { tag: 1 }))));
note("a primitive target:", Object.assign(5, { a: 1 }) == 5, caught(function () { return Object.assign(null, {}); }), caught(function () { return Object.assign(undefined); }));
note("what assign makes:", described(Object.assign({}, mixed)), described(Object.assign({}, watched)));

// --- spread and rest ---
note("spread:", described({ before: 0, ...record, after: 9 }), described({ ...record, id: "over" }), described({ id: "under", ...record }));
note("spread of two:", described({ ...{ a: 1, b: 2 }, ...{ b: "second", c: 3 } }), described({ ...null, ...undefined, ...5, ..."ab", ...[7, 8] }));
note("spread of what is not plain:", described({ ...mixed }), described({ ...ordered }), described({ ...watched }));
var { id, name, ...rest } = record;
note("rest:", id, name, described(rest));
var { a: restA, [marked]: restMarked, ...restMixed } = mixed;
note("rest of a mixed one:", restA, restMarked, described(restMixed));
var { 2: two, b: restB, ...restOrdered } = ordered;
note("rest past an index name:", two, restB, described(restOrdered));
var { ...whole } = watched;
note("rest of everything:", described(whole), whole !== watched);

// --- for-in ---
var base = { inherited: 1, shadowed: "base" };
var child = Object.create(base);
child.own = 2; child.shadowed = "child";
note("for-in through a prototype:", forIn(child), Object.keys(child).join());
Object.defineProperty(child, "inherited", { value: "hidden here", enumerable: false, configurable: true });
note("hidden by one that is not enumerable:", forIn(child));
function Point(x, y) { this.x = x; this.y = y; }
Point.prototype.norm = function () { return 0; };
class Shape { constructor() { this.kind = "shape"; this.sides = 0; } area() { return 0; } }
note("instances:", forIn(new Point(1, 2)), forIn(new Shape()), Object.keys(new Point(1, 2)).join(), Object.keys(new Shape()).join());
var visited = [];
var growing = { a: 1, b: 2, c: 3, d: 4 };
for (var key in growing) { visited.push(key); growing.late = 1; }
note("for-in while it grows:", visited.join(), Object.keys(growing).join());
note("for-in over others:", forIn([7, 8]), forIn("ab"), forIn(5), forIn(null), forIn(function () {}), forIn(ordered), forIn(Object.create(null)), forIn(Object.assign(Object.create({ deep: 1 }), { 2: "b", 1: "a", z: 0 })));

// --- what is not a plain object ---
var wrapped = Object.assign(new String("ab"), { extra: 1 });
note("a string wrapper:", Object.keys(wrapped).join(), Object.values(wrapped).join(), pairs(wrapped), Object.getOwnPropertyNames(wrapped).join(), described(Object.assign({}, wrapped)), described({ ...wrapped }));
note("a number wrapper:", every(Object.assign(new Number(5), { extra: 1 })));
note("an array:", every(Object.assign([7, , 9], { extra: 1 })));
var sparse = [1, 2];
sparse[100000] = "far"; sparse.extra = 1; sparse[50000] = "nearer";
note("a sparse array:", every(sparse));
sparse.length = 60000;
note("and shortened:", every(sparse), sparse.length);
note("a function:", Object.keys(Object.assign(function named(a) {}, { extra: 1 })).join(), Object.getOwnPropertyNames(function named(a) {}).sort().join());
note("primitives:", Object.keys("ab").join(), Object.values("ab").join(), Object.keys(5).length, caught(function () { return Object.keys(null); }), caught(function () { return Object.entries(undefined); }));
(function () { note("arguments:", every(arguments), Object.values(arguments).join()); })("x", "y");
(function (p, q) { p = "changed"; note("mapped arguments:", Object.values(arguments).join(), pairs(arguments), described({ ...arguments })); })("x", "y");
globalThis.declaredHere = 1;
note("the global object:", Object.keys(globalThis).includes("declaredHere"), Object.getOwnPropertyNames(globalThis).includes("Object"), Object.keys(globalThis).includes("Object"), forIn(globalThis).split(",").includes("declaredHere"), Object.values(globalThis).includes(1), "declaredHere" in { ...globalThis }, Object.assign({}, globalThis).declaredHere);
note("others with hidden state:", "[" + Object.keys(new Map([[1, 2]])).join() + "]", "[" + Object.keys(new Date(0)).join() + "]", "[" + Object.keys(/x/g).join() + "]", Object.getOwnPropertyNames(/x/g).join(), "[" + Object.keys(new Error("m")).join() + "]", Object.getOwnPropertyNames(new Error("m")).filter(function (n) { return n != "stack"; }).join(), Object.keys(Object.assign(new Map(), { tag: 1 })).join());
class Counter { #count = 0; visible = 1; static made = 0; }
note("private and static names:", Object.keys(new Counter()).join(), Object.getOwnPropertyNames(new Counter()).join(), Object.keys(Counter).join(), described({ ...new Counter() }));
note("frozen and sealed:", every(Object.freeze({ a: 1, b: 2 })), Object.keys(Object.seal({ a: 1 })).join(), Object.isFrozen(Object.assign({}, Object.freeze({ a: 1 }))));

console.log(log.join("\n"));
