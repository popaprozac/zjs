// Spreading an array, and Array.from of one, copy its elements without
// running the iterator protocol when nothing about array iteration has
// been changed. Everything a program can change must still be seen:
// the array's own Symbol.iterator, Array.prototype's, the iterator's
// `next`, the array's prototype; and the copy must read what the
// iterator would read, at the time it would read it.
var log = [];
function note() { var parts = []; for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i])); log.push(parts.join(" ")); }
function show(list) { var parts = []; for (var i = 0; i < list.length; i++) parts.push(i in list ? String(list[i]) : "-"); return "[" + parts.join(",") + "]"; }
function caught(run) { try { return run(); } catch (error) { return error.constructor.name; } }
function count() { return arguments.length; }
function joined() { return Array.prototype.join.call(arguments, "/"); }
var from = Array.from, iteratorKey = Symbol.iterator;

// --- ordinary arrays ---
var plain = [1, "two", null, undefined, 4.5];
note("spread:", show([...plain]), show([0, ...plain, 9]), show([...plain, ...plain]), [...plain] === plain, show([...[]]), show([...[], 1, ...[2]]));
note("in calls:", joined(...plain), count(...plain, ...plain), Math.max(...[3, 9, 4]), new Date(...[2020, 0, 2]).getDate(), [].concat(...[[1], [2, 3]]).length, String.fromCharCode(...[104, 105]));
note("Array.from:", show(from(plain)), from(plain) === plain, show(from(plain, function (x, i) { return i + ":" + x; })), show(from([])), from([1, 2, 3], function (x) { return this.k * x; }, { k: 10 }).join());
var long = [];
for (var n = 0; n < 3000; n++) long.push(n);
note("long:", [...long].length, [...long][2999], from(long).length, count(...long), [...long, ...long].length);

// --- holes ---
var holed = [1, , 3, , ];
note("holes:", show([...holed]), [...holed].hasOwnProperty(1), show(from(holed)), count(...holed), joined(...holed));
Array.prototype[1] = "filled";
note("filled by the prototype:", show([...holed]), show(from(holed)), joined(...holed));
delete Array.prototype[1];

// --- accessors, and a source that changes as it is read ---
var reads = [];
var watched = [10, 20, 30];
Object.defineProperty(watched, 1, { get: function () { reads.push("get 1"); return 21; }, enumerable: true, configurable: true });
note("an accessor:", show([...watched]), show(from(watched)), reads.join());
var growing = [1, 2, 3];
Object.defineProperty(growing, 0, { get: function () { if (growing.length < 6) growing.push("late" + growing.length); return 1; }, configurable: true });
note("a getter that lengthens:", show([...growing]), growing.length);
var shrinking = [1, 2, 3, 4, 5];
Object.defineProperty(shrinking, 1, { get: function () { shrinking.length = 3; return "got"; }, configurable: true });
note("a getter that shortens:", show([...shrinking]), show(shrinking));
var rewriting = [1, 2, 3, 4];
Object.defineProperty(rewriting, 0, { get: function () { rewriting[3] = "changed"; return 1; }, configurable: true });
note("a getter that changes a later one:", show([...rewriting]), show(from(rewriting)));
var failing = [1, 2, 3];
Object.defineProperty(failing, 1, { get: function () { throw new RangeError("no"); }, configurable: true });
note("a getter that throws:", caught(function () { return [...failing]; }), caught(function () { return from(failing); }), caught(function () { return count(...failing); }));
var frozen = Object.freeze([1, 2, 3]);
note("frozen:", show([...frozen]), Object.isFrozen([...frozen]), show(from(frozen)));

// --- the array's own iterator, and its prototype ---
var own = [1, 2, 3];
own[iteratorKey] = function* () { yield "own"; yield "iterator"; };
note("its own iterator:", show([...own]), show(from(own)), joined(...own));
delete own[iteratorKey];
note("deleted:", show([...own]));
own.tag = "named";
note("another property of its own:", show([...own]), [...own].tag, show(from(own)));
var moved = [1, 2, 3];
Object.setPrototypeOf(moved, { [iteratorKey]: function* () { yield "from another prototype"; } });
note("another prototype:", show([...moved]), show(from(moved)));
Object.setPrototypeOf(moved, Array.prototype);
note("and back:", show([...moved]));
var bare = [1, 2];
Object.setPrototypeOf(bare, null);
note("none:", caught(function () { return [...bare]; }), show(from(bare)));

// --- Array.prototype[Symbol.iterator] ---
var values = Array.prototype[iteratorKey];
var calls = 0;
Array.prototype[iteratorKey] = function () { calls++; return values.call(this); };
note("wrapped:", show([...plain]), show(from(plain)), joined(...[1, 2]), calls);
Array.prototype[iteratorKey] = function* () { yield "replaced"; };
note("replaced:", show([...plain]), show(from(plain)), count(...plain));
Object.defineProperty(Array.prototype, iteratorKey, { get: function () { calls++; return values; }, configurable: true });
calls = 0;
note("a getter:", show([...[7, 8]]), show(from([7, 8])), calls);
Object.defineProperty(Array.prototype, iteratorKey, { value: values, writable: true, configurable: true });
note("restored:", show([...plain]), show(from(plain)));
Array.prototype.values = function () { return "not used"; };
note("values replaced, which spread does not read:", show([...[1, 2]]), show(from([1, 2])));
Array.prototype.values = values;

// --- the iterator's next ---
var iteratorProto = Object.getPrototypeOf([][iteratorKey]());
var next = iteratorProto.next;
var steps = 0;
iteratorProto.next = function () { steps++; var result = next.call(this); if (!result.done) result.value = "stepped " + result.value; return result; };
note("next wrapped:", show([...[1, 2]]), show(from([3])), joined(...[4]), steps);
iteratorProto.next = function () { return { done: true }; };
note("next that ends at once:", show([...plain]), show(from(plain)), count(...plain));
Object.defineProperty(iteratorProto, "next", { get: function () { steps++; return next; }, configurable: true });
steps = 0;
note("next as a getter:", show([...[1, 2, 3]]), steps);
delete iteratorProto.next;
note("next deleted:", caught(function () { return [...plain]; }), caught(function () { return from(plain); }));
iteratorProto.next = next;
note("next restored:", show([...plain]), show(from(plain)), joined(...[1, 2]));

// --- Array.from with a function, which runs between the reads ---
var fed = [1, 2, 3];
note("a function that lengthens:", show(from(fed, function (x, i) { if (fed.length < 6) fed.push("late" + i); return x; })), fed.length);
fed = [1, 2, 3, 4, 5];
note("that shortens:", show(from(fed, function (x) { fed.length = 3; return x; })));
fed = [1, 2, 3, 4];
note("that changes later ones:", show(from(fed, function (x, i) { if (i == 0) { fed[3] = "changed"; delete fed[1]; } return x; })));
fed = [1, 2, 3];
note("that throws:", caught(function () { return from(fed, function (x) { if (x == 2) throw new RangeError("no"); return x; }); }));
note("that replaces the iterator and its next:", show(from(fed, function (x) { Array.prototype[iteratorKey] = function* () { yield "not read again"; }; iteratorProto.next = function () { return { done: true }; }; return x * 2; })), show([...fed]));
Array.prototype[iteratorKey] = values;
iteratorProto.next = next;
note("put back:", show(from(fed, function (x) { return x + 1; })), show([...fed]));

// --- Array.from with another receiver, made after Symbol.iterator is read and before next is ---
function Restoring() { Array.prototype[iteratorKey] = values; return []; }
Array.prototype[iteratorKey] = function* () { yield "read before the receiver ran"; };
note("a receiver that restores the iterator:", show(from.call(Restoring, [1, 2])), show(from([1, 2])));
function Replacing() { Array.prototype[iteratorKey] = function* () { yield "not this one"; }; return []; }
note("one that replaces it:", show(from.call(Replacing, [1, 2])), show(from([1, 2])));
Array.prototype[iteratorKey] = values;
function Ending() { iteratorProto.next = function () { return { done: true }; }; return []; }
note("one that replaces next:", show(from.call(Ending, [1, 2])));
iteratorProto.next = next;
note("and all put back:", show(from.call(Restoring, [1, 2])), show(from([1, 2], function (x) { return x * 3; })));

// --- Array.prototype changing shape around its iterator ---
// Run with the function Symbol.iterator had in every other place on
// Array.prototype that can hold it: where the iterator was found before
// the prototype was laid out anew is then no place to look.
function everywhere(run) {
  var names = Object.getOwnPropertyNames(Array.prototype), held = [], at;
  for (at = 0; at < names.length; at++) { var found = Object.getOwnPropertyDescriptor(Array.prototype, names[at]); held[at] = found.writable && typeof found.value == "function" ? found : null; }
  for (at = 0; at < names.length; at++) if (held[at]) Array.prototype[names[at]] = values;
  var result = caught(run);
  for (at = 0; at < names.length; at++) if (held[at]) Array.prototype[names[at]] = held[at].value;
  return result;
}
Array.prototype.extra = function () { return "extra"; };
note("a method added:", show([...[1, 2]]), show(from([1, 2])));
Array.prototype[iteratorKey] = function* () { yield "replaced after"; };
note("then the iterator replaced:", show([...[1, 2]]), show(from([1, 2])));
Array.prototype[iteratorKey] = values;
delete Array.prototype.extra;
for (var k = 0; k < 80; k++) Array.prototype["crowd" + k] = k;
note("a crowded prototype:", show([...[1, 2]]), show(from([1, 2])), [].crowd79);
Array.prototype[iteratorKey] = function* () { yield "replaced in the crowd"; };
note("its iterator replaced:", show([...[1, 2]]), show(from([1, 2])));
Array.prototype[iteratorKey] = values;
for (var k2 = 0; k2 < 80; k2++) delete Array.prototype["crowd" + k2];
note("uncrowded:", show([...[1, 2]]), show(from([1, 2])), joined(...[1, 2]));
delete Array.prototype[iteratorKey];
note("deleted:", caught(function () { return [...plain]; }), show(from([5, 6])), caught(function () { return count(...plain); }));
for (var churn = 0; churn < 1500; churn++) { Array.prototype.churned = churn; delete Array.prototype.churned; }
note("deleted, and the prototype packed down:", everywhere(function () { return [...[1, 2]].length; }), everywhere(function () { return from([1, 2]).length; }));
Array.prototype.late = 1;
Object.defineProperty(Array.prototype, iteratorKey, { value: function* () { yield "found again"; }, writable: true, configurable: true });
note("another put back:", show([...[1, 2]]), everywhere(function () { return [...[1, 2]].length; }));
Array.prototype[iteratorKey] = values;
delete Array.prototype.late;
note("and the first:", show([...[1, 2]]), show(from([1, 2])), joined(...[1, 2]));

// --- other iterables, which go the long way ---
function* three() { yield 1; yield 2; yield 3; }
note("others:", show([..."héllo"]), show([...new Set([1, 2, 2, 3])]), show([...new Map([[1, 2]])]), show([...three()]), show(from({ length: 2, 0: "a", 1: "b" })), show(from("ab")), show(from(new Set([4, 5]), function (x) { return x * 2; })));
(function () { note("arguments:", show([...arguments]), show(from(arguments)), count(...arguments)); })(1, 2, 3);
note("not iterable:", caught(function () { return [...5]; }), caught(function () { return [...null]; }), caught(function () { return [...{}]; }), show(from(5)), caught(function () { return from(null); }));

console.log(log.join("\n"));
