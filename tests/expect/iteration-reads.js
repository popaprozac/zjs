// What an iteration reads, and when: an iterable's Symbol.iterator once,
// and its iterator's `next` once, when the iterator is got, however many
// steps follow; and Array.from calling its mapping function on each value
// as that value is produced.
// A string's iterator reads a `next` of its own.
// Closing an iterator reads its `return`.
// Array.from reads Symbol.iterator as a method, and defines each value on
// its result as that value is produced.

// An iterable that counts each read of Symbol.iterator and of `next`,
// each call of `next`, and each call of `return`.
function counted(values) {
  var log = { iterator: 0, next: 0, calls: 0, closed: 0 };
  var iterable = { log: log };
  Object.defineProperty(iterable, Symbol.iterator, { get: function () {
    log.iterator++;
    return function () {
      var i = 0, iterator = { return: function () { log.closed++; return {}; } };
      Object.defineProperty(iterator, "next", { get: function () {
        log.next++;
        return function () { log.calls++; return i < values.length ? { value: values[i++], done: false } : { value: undefined, done: true }; };
      } });
      return iterator;
    };
  } });
  return iterable;
}
function show(label, iterable, result) {
  var log = iterable.log;
  console.log(label + ":", "Symbol.iterator", log.iterator, "next", log.next, "calls", log.calls, "closed", log.closed, "->", String(result));
}
function attempt(f) { try { return String(f()); } catch (e) { return e.constructor.name; } }
var c, key1 = {}, key2 = {};

// --- Statements and expressions ---
c = counted([1, 2, 3]); var sum = 0; for (var v of c) sum += v; show("for-of", c, sum);
c = counted([1, 2, 3]); for (var v of c) break; show("for-of, break", c, v);
c = counted([1, 2, 3]); show("spread into an array", c, [0, ...c, 4]);
c = counted([1, 2, 3]); show("spread into a call", c, Math.max(...c));
c = counted([1, 2, 3]); var [a, b] = c; show("destructuring two", c, a + b);
c = counted([1, 2, 3]); var [first, ...rest] = c; show("destructuring with a rest", c, rest);
c = counted([1, 2, 3]); var [] = c; show("destructuring none", c, "no step");
c = counted([1, 2, 3]); function* through() { return yield* c; } show("yield*", c, [...through()]);

// --- Builtins that iterate ---
c = counted([1, 2, 3]); show("Array.from", c, Array.from(c));
c = counted([1, 2, 3]); show("Array.from, mapped", c, Array.from(c, function (x) { return x * 2; }));
c = counted([[1, "a"], [2, "b"]]); show("new Map", c, new Map(c).size);
c = counted([1, 2, 2]); show("new Set", c, new Set(c).size);
c = counted([[key1, 1], [key2, 2]]); show("new WeakMap", c, new WeakMap(c).get(key2));
c = counted([key1, key2]); show("new WeakSet", c, new WeakSet(c).has(key1));
c = counted([1, 2, 3]); show("Map.groupBy", c, Map.groupBy(c, function (x) { return x % 2; }).get(1));
c = counted([1, 2, 3]); show("Object.groupBy", c, Object.groupBy(c, function (x) { return x % 2 ? "odd" : "even"; }).odd);
c = counted([1, 2]); show("AggregateError", c, new AggregateError(c).errors);
c = counted([1, 2]); Promise.all(c); show("Promise.all", c, "started");
c = counted([1, 2]); Promise.allSettled(c); show("Promise.allSettled", c, "started");
c = counted([1, 2]); Promise.any(c); show("Promise.any", c, "started");
c = counted([1, 2]); Promise.race(c); show("Promise.race", c, "started");
// A set-like's keys() result is stepped the same way: its `next` once.
c = counted([1, 2, 3, 4, 5]);
var setLike = { size: 5, has: function () { return true; }, keys: c[Symbol.iterator] };
show("Set.prototype.union", c, [...new Set([9]).union(setLike)]);
c = counted([1, 2, 3, 4, 5]);
setLike = { size: 5, has: function () { return true; }, keys: c[Symbol.iterator] };
show("Set.prototype.isSupersetOf", c, new Set([1, 2, 3, 4, 5]).isSupersetOf(setLike));

// --- Array.from: the mapping function runs between the steps ---
var src = [1, 2, 3];
console.log("map between steps, array:", Array.from(src, function (x) { src[2] = "changed"; return x; }).join());
src = { length: 3, 0: 1, 1: 2, 2: 3 };
console.log("map between steps, array-like:", Array.from(src, function (x) { src[2] = "changed"; return x; }).join());
src = [1, 2, 3];
console.log("map sees a longer source:", Array.from(src, function (x, i) { if (i == 0) src.push(4); return x; }).join());
// The same through a receiver other than Array.
class Stack extends Array {}
src = [1, 2, 3];
var stacked = Stack.from(src, function (x) { src[2] = "changed"; return x; });
console.log("map between steps, subclass:", stacked instanceof Stack, stacked.join());
var receiver = { scale: 10 };
console.log("map arguments:", Array.from("ab", function (x, i) { return x + i + this.scale + arguments.length; }, receiver).join());
// A mapping function that throws stops the iteration there and closes
// the iterator: an endless source is no obstacle.
var endless = { made: 0, closed: 0 };
endless[Symbol.iterator] = function () {
  return { next: function () { endless.made++; return { value: endless.made, done: false }; }, return: function () { endless.closed++; return {}; } };
};
try { Array.from(endless, function (x) { if (x == 3) throw new RangeError("stop at " + x); return x; }); } catch (e) { console.log("map throws:", e.message, "made", endless.made, "closed", endless.closed); }
// The close's own throw does not replace the mapping function's.
endless = { made: 0, closed: 0 };
endless[Symbol.iterator] = function () {
  return { next: function () { endless.made++; return { value: endless.made, done: false }; }, return: function () { endless.closed++; throw new Error("from return"); } };
};
try { Array.from(endless, function (x) { throw new RangeError("from map"); }); } catch (e) { console.log("map throws, return throws:", e.message, "closed", endless.closed); }
console.log("not callable:", (function () { try { Array.from([1], 5); } catch (e) { return e.constructor.name; } })());

// --- Array.from: Symbol.iterator is read as a method ---
function withIterator(value) { var o = { length: 2, 0: "a", 1: "b" }; o[Symbol.iterator] = value; return o; }
console.log("Symbol.iterator undefined or null:", attempt(function () { return Array.from(withIterator(undefined)); }), attempt(function () { return Array.from(withIterator(null)); }));
console.log("Symbol.iterator not callable:", attempt(function () { return Array.from(withIterator(5)); }), attempt(function () { return Array.from(withIterator(0)); }), attempt(function () { return Array.from(withIterator("")); }), attempt(function () { return Array.from(withIterator(false)); }), attempt(function () { return Array.from(withIterator({})); }));
var builds = 0;
function Counting() { builds++; return []; }
console.log("not callable, before the receiver is constructed:", attempt(function () { return Array.from.call(Counting, withIterator(5)); }), builds);

// --- Array.from on a receiver other than Array: each value is defined
// on the receiver's object as it is produced ---
var events = [];
function Fixed() { return Object.defineProperty({}, "1", { value: "fixed", writable: false, configurable: false }); }
c = counted([10, 20, 30]);
console.log("a define that throws, iterable:", attempt(function () { return Array.from.call(Fixed, c); }), "calls", c.log.calls, "closed", c.log.closed);
c = counted([10, 20, 30]);
console.log("a define that throws, mapped:", attempt(function () { return Array.from.call(Fixed, c, function (x, i) { events.push("map " + i); return x; }); }), "calls", c.log.calls, "closed", c.log.closed, events.join());
events = [];
console.log("a define that throws, array-like:", attempt(function () { return Array.from.call(Fixed, { length: 3, 0: "a", 1: "b", 2: "c" }, function (x, i) { events.push("map " + i); return x; }); }), events.join());
// The close's own throw does not replace the define's, and an endless
// source is no obstacle here either.
endless = { [Symbol.iterator]: function () { return { next: function () { return { value: 1, done: false }; }, return: function () { throw new EvalError("from return"); } }; } };
console.log("a define that throws, return throws:", attempt(function () { return Array.from.call(Fixed, endless); }));
// The order: construct, then for each value step, map, define; `length` last.
events = [];
function Traced() {
  events.push("construct " + arguments.length);
  return Object.defineProperty({}, "length", { set: function (v) { events.push("length=" + v); }, get: function () { return 0; }, configurable: true });
}
var stepped = { [Symbol.iterator]: function () { events.push("iterator"); var i = 0; return { next: function () { events.push("step " + i); return i < 2 ? { value: i++, done: false } : { done: true }; } }; } };
var filled = Array.from.call(Traced, stepped, function (x, i) { events.push("map " + i); return x * 10; });
console.log("order, iterable:", events.join(", "), "->", Object.keys(filled).join(), filled[0], filled[1]);
events = [];
filled = Array.from.call(Traced, { length: 2, get 0() { events.push("get 0"); return "a"; }, get 1() { events.push("get 1"); return "b"; } }, function (x, i) { events.push("map " + i); return x; });
console.log("order, array-like:", events.join(", "), "->", Object.keys(filled).join());
// The same from an array, which is read without making its iterator.
events = [];
console.log("a define that throws, array:", attempt(function () { return Array.from.call(Fixed, [10, 20, 30], function (x, i) { events.push("map " + i); return x; }); }), events.join());
events = [];
filled = Array.from.call(Traced, [5, 6], function (x, i) { events.push("map " + i); return x * 10; });
console.log("order, array:", events.join(", "), "->", Object.keys(filled).join(), filled[0], filled[1]);
// A frozen receiver's object: the first define throws, after one step.
c = counted([1, 2, 3]);
console.log("frozen:", attempt(function () { return Array.from.call(function () { return Object.freeze({}); }, c); }), "calls", c.log.calls, "closed", c.log.closed);
Object.getPrototypeOf([][Symbol.iterator]()).return = function () { events.push("closed, next would give " + this.next().value); return {}; };
events = [];
console.log("a define that throws, array, with a return:", attempt(function () { return Array.from.call(Fixed, [10, 20, 30]); }), events.join());
delete Object.getPrototypeOf([][Symbol.iterator]()).return;
// A length that cannot be set throws once every value is defined.
function ReadOnlyLength() { return Object.defineProperty({}, "length", { value: 0, writable: false }); }
c = counted([1, 2]);
console.log("read-only length:", attempt(function () { return Array.from.call(ReadOnlyLength, c); }), "calls", c.log.calls, "closed", c.log.closed);
// A subclass, and receivers that are not constructors.
stacked = Stack.from(counted([1, 2, 3]), function (x) { return x + 1; });
console.log("subclass:", stacked instanceof Stack, stacked.length, stacked.join(), Stack.from({ length: 2, 0: "x", 1: "y" }).join(), Stack.from([]).length);
console.log("not a constructor:", Array.isArray(Array.from.call({}, [1, 2])), Array.from.call(undefined, "ab").join(), Array.from.call(Math.max, [3]).length);

// --- Symbol.iterator on Array.prototype, as a getter ---
var reads = 0, values = Array.prototype[Symbol.iterator];
Object.defineProperty(Array.prototype, Symbol.iterator, { get: function () { reads++; return values; }, configurable: true });
reads = 0; Array.from([1, 2]); console.log("Symbol.iterator reads, Array.from:", reads);
reads = 0; Array.from([1, 2], function (x) { return x; }); console.log("Symbol.iterator reads, Array.from mapped:", reads);
reads = 0; for (var v of [1, 2]) {} console.log("Symbol.iterator reads, for-of:", reads);
reads = 0; var copy = [...[1, 2]]; console.log("Symbol.iterator reads, spread:", reads);
reads = 0; var [p, q] = [1, 2]; console.log("Symbol.iterator reads, destructuring:", reads);
reads = 0; new Set([1, 2]); console.log("Symbol.iterator reads, new Set:", reads);
Object.defineProperty(Array.prototype, Symbol.iterator, { value: values, writable: true, configurable: true });

// --- The array iterator's `next`, as a getter ---
var proto = Object.getPrototypeOf([][Symbol.iterator]()), next = proto.next, steps = 0;
Object.defineProperty(proto, "next", { get: function () { steps++; return next; }, configurable: true });
steps = 0; var seen = 0; for (var x of [1, 2, 3]) seen++; console.log("next reads, for-of over three:", steps, "seen", seen);
steps = 0; console.log("next reads, spread:", [...[1, 2, 3]].join(), steps);
steps = 0; var [d1, d2, ...d3] = [1, 2, 3, 4]; console.log("next reads, destructuring:", d1, d2, d3.join(), steps);
steps = 0; console.log("next reads, Array.from:", Array.from([1, 2, 3]).join(), steps);
steps = 0; console.log("next reads, new Map:", new Map([[1, 2], [3, 4]]).size, steps);
steps = 0; function* delegate() { yield* [1, 2, 3]; } console.log("next reads, yield*:", [...delegate()].join(), steps);
Object.defineProperty(proto, "next", { value: next, writable: true, configurable: true });

// --- The `next` read when the iterator was got is the one every step calls ---
seen = [];
for (var x of [1, 2, 3]) { seen.push(x); proto.next = function () { return { done: true }; }; }
proto.next = next;
console.log("next replaced mid-loop, array:", seen.join());
seen = [];
var own = { i: 0, [Symbol.iterator]: function () { return this; }, next: function () { return this.i < 3 ? { value: this.i++, done: false } : { done: true }; } };
for (var x of own) { seen.push(x); own.next = function () { return { done: true }; }; }
console.log("next replaced mid-loop, own:", seen.join());
// Replaced before the loop, it is the replacement that runs.
proto.next = function () { return { done: true }; };
seen = []; for (var x of [1, 2, 3]) seen.push(x);
proto.next = next;
console.log("next replaced before the loop:", seen.length);
// An array iterator with a `next` of its own.
var withOwn = [1, 2, 3][Symbol.iterator]();
withOwn.next = function () { return { done: true }; };
console.log("an own next:", [...withOwn].length);
// The builtin `next` borrowed by another object's iterator.
var borrowed = { [Symbol.iterator]: function () { return { next: next }; } };
console.log("builtin next, wrong receiver:", (function () { try { return [...borrowed]; } catch (e) { return e.constructor.name; } })());

// --- When `next` is read: once the iterator is got, before any step ---
var order = [];
var traced = {};
Object.defineProperty(traced, Symbol.iterator, { get: function () {
  order.push("get @@iterator");
  return function () {
    order.push("call @@iterator");
    var i = 0, iterator = {};
    Object.defineProperty(iterator, "next", { get: function () { order.push("get next"); return function () { order.push("call next"); return { value: i, done: i++ == 2 }; }; } });
    return iterator;
  };
} });
for (var x of traced) order.push("body " + x);
console.log("order:", order.join(", "));
// A `next` that is not callable fails at the first step, not before.
var noNext = { [Symbol.iterator]: function () { return {}; } };
console.log("no next, for-of:", (function () { try { for (var x of noNext) {} return "ran"; } catch (e) { return e.constructor.name; } })());
console.log("no next, no step:", (function () { try { var [] = noNext; return "ran"; } catch (e) { return e.constructor.name; } })());
// A `next` getter that throws fails when the iterator is got, steps or not.
var throwingNext = { [Symbol.iterator]: function () { return { get next() { throw new RangeError("next getter"); } }; } };
console.log("next getter throws, no step:", (function () { try { var [] = throwingNext; return "ran"; } catch (e) { return e.message; } })());
console.log("next getter throws, Array.from:", (function () { try { return Array.from(throwingNext); } catch (e) { return e.message; } })());

// --- A string's iterator has a prototype, and a `next`, of its own ---
var arrayIterProto = Object.getPrototypeOf([][Symbol.iterator]());
var stringIterProto = Object.getPrototypeOf(""[Symbol.iterator]());
var arrayNext = arrayIterProto.next, stringNext = stringIterProto.next;
console.log("string iterator prototype:", stringIterProto !== arrayIterProto, Object.getPrototypeOf(stringIterProto) === Object.getPrototypeOf(arrayIterProto), stringNext !== arrayNext);
console.log("tags:", Object.prototype.toString.call(""[Symbol.iterator]()), Object.prototype.toString.call([][Symbol.iterator]()), Object.prototype.toString.call(Array.prototype.values.call("ab")));
console.log("own names:", Object.getOwnPropertyNames(stringIterProto).join(), stringIterProto[Symbol.toStringTag], stringNext.name, stringNext.length);
console.log("next on the other kind:", attempt(function () { return arrayNext.call("ab"[Symbol.iterator]()); }), attempt(function () { return stringNext.call([1][Symbol.iterator]()); }), attempt(function () { return stringNext.call({}); }), attempt(function () { return stringNext.call("ab"[Symbol.iterator]()).value; }));
// By code point through its own iterator; by index through an array iterator.
var astral = "a\uD83D\uDE00b";
console.log("code points:", [...astral].length, Array.from(astral).length, [...Array.prototype.values.call(astral)].length, [...Array.prototype.keys.call(astral)].join());
Object.defineProperty(arrayIterProto, "next", { get: function () { steps++; return arrayNext; }, configurable: true });
steps = 0; var spelled = [..."abc"].join(); console.log("array iterator's next, read by a string:", spelled, steps);
Object.defineProperty(arrayIterProto, "next", { value: arrayNext, writable: true, configurable: true });
Object.defineProperty(stringIterProto, "next", { get: function () { steps++; return stringNext; }, configurable: true });
steps = 0; spelled = [..."abc"].join(); console.log("string iterator's next, read by a string:", spelled, steps);
steps = 0; seen = ""; for (var ch of "abc") seen += ch; console.log("string iterator's next, for-of:", seen, steps);
steps = 0; var [s1, s2] = "xyz"; console.log("string iterator's next, destructuring:", s1 + s2, steps);
steps = 0; copy = [...[1, 2, 3]].join(); console.log("string iterator's next, read by an array:", copy, steps);
Object.defineProperty(stringIterProto, "next", { value: stringNext, writable: true, configurable: true });
stringIterProto.next = function () { return { done: true }; };
console.log("string next replaced before the loop:", [..."abc"].length, [...[1, 2]].length);
stringIterProto.next = stringNext;
seen = ""; for (var ch of "abc") { seen += ch; stringIterProto.next = function () { return { done: true }; }; }
stringIterProto.next = stringNext;
console.log("string next replaced mid-loop:", seen);
function* spell() { yield* "hi"; }
console.log("yield* over a string:", [...spell()].join());

// --- Closing an iterator looks for `return` along its prototypes ---
var closed = [];
function closer(where) { return function () { closed.push(where); return {}; }; }
function closes() {
  closed = [];
  for (var x of [1, 2, 3]) break;
  var [first] = [1, 2];
  var [p, q] = [1, 2];
  var [head, ...tail] = [1, 2];
  for (var y of [1, 2]) {}
  var [letter] = "abc";
  for (var z of "abc") break;
  return closed.length + ":" + closed.join();
}
console.log("no return anywhere:", closes());
arrayIterProto.return = closer("array");
console.log("return on the array iterator's prototype:", closes());
delete arrayIterProto.return;
console.log("deleted again:", closes());
stringIterProto.return = closer("string");
console.log("return on the string iterator's prototype:", closes());
delete stringIterProto.return;
var iteratorProto = Object.getPrototypeOf(arrayIterProto);
iteratorProto.return = closer("iterator");
console.log("return on %IteratorPrototype%:", closes());
delete iteratorProto.return;
Object.prototype.return = closer("object");
console.log("return on Object.prototype:", closes());
delete Object.prototype.return;
console.log("none again:", closes());
reads = 0;
Object.defineProperty(arrayIterProto, "return", { get: function () { reads++; return undefined; }, configurable: true });
closes(); console.log("return as a getter giving undefined: reads", reads);
delete arrayIterProto.return;
own = [1, 2, 3][Symbol.iterator]();
own.return = closer("own");
closed = []; for (var x of own) break; console.log("an own return:", closed.join());
arrayIterProto.return = function () { return 1; };
console.log("return gives a non-object:", attempt(function () { for (var x of [1, 2]) break; return "ran"; }), attempt(function () { for (var x of [1, 2]) throw new RangeError("body"); }));
arrayIterProto.return = function () { throw new EvalError("from return"); };
console.log("return throws:", attempt(function () { var [only] = [1, 2]; return "ran"; }), attempt(function () { for (var x of [1, 2]) throw new RangeError("body"); }));
delete arrayIterProto.return;
// A mapped Array.from of an array makes no iterator, and closes the one
// it stands in for, where that one would be.
arrayIterProto.return = function () { closed.push("array, whose next would give " + this.next().value); return {}; };
closed = []; attempt(function () { return Array.from([1, 2, 3], function (x) { if (x == 2) throw new RangeError("map"); return x; }); });
attempt(function () { return Array.from([1, 2, 3], function (x) { return x; }); });
console.log("Array.from of an array, the mapping function throws:", closed.join());
delete arrayIterProto.return;
// Other iterators: a Map's has none until it is given one, a generator's
// is its own.
var mapIterProto = Object.getPrototypeOf(new Map()[Symbol.iterator]());
closed = []; for (var e of new Map([[1, 2]])) break;
mapIterProto.return = closer("map");
for (var e of new Map([[1, 2]])) break;
delete mapIterProto.return;
for (var e of new Map([[1, 2]])) break;
console.log("a Map iterator's return:", closed.join());
function* finishing() { try { yield 1; yield 2; } finally { closed.push("generator finally"); } }
closed = []; for (var g of finishing()) break; for (var g of finishing()) break; console.log("a generator's return:", closed.join());

// --- for await and async yield*: a sync iterable goes through the same
// iteration, and an async iterator's `next` is read once as well ---
function countedAsync(values) {
  var log = { iterator: 0, next: 0, calls: 0, closed: 0, passed: [] };
  var iterable = { log: log };
  Object.defineProperty(iterable, Symbol.asyncIterator, { get: function () {
    log.iterator++;
    return function () {
      var i = 0, iterator = { return: async function () { log.closed++; return {}; } };
      Object.defineProperty(iterator, "next", { get: function () {
        log.next++;
        return async function () { log.calls++; log.passed.push(arguments.length); return i < values.length ? { value: values[i++], done: false } : { value: undefined, done: true }; };
      } });
      return iterator;
    };
  } });
  return iterable;
}
function showAsync(label, iterable, result) {
  var log = iterable.log;
  console.log(label + ":", "Symbol.asyncIterator", log.iterator, "next", log.next, "calls", log.calls, "closed", log.closed, "arguments", log.passed.join(""), "->", String(result));
}
async function attemptAsync(f) { try { return String(await f()); } catch (e) { return e.constructor.name + ": " + e.message.replace(/.* is not a function/, "not a function"); } }
(async function () {
  var c = counted([1, 2, 3]), sum = 0;
  for await (var v of c) sum += v;
  show("for await, sync iterable", c, sum);
  c = counted([1, 2, 3]);
  async function* through() { return yield* c; }
  var got = [];
  for await (var v of through()) got.push(v);
  show("async yield*, sync iterable", c, got);

  c = countedAsync([1, 2, 3]); sum = 0;
  for await (var v of c) sum += v;
  showAsync("for await, async iterable", c, sum);
  c = countedAsync([1, 2, 3]);
  for await (var v of c) break;
  showAsync("for await, break", c, v);
  c = countedAsync([1, 2, 3]);
  async function* throughAsync() { return yield* c; }
  got = [];
  for await (var v of throughAsync()) got.push(v);
  showAsync("async yield*, async iterable", c, got);

  // The `next` read when the iterator was got is the one every step calls.
  var own = { i: 0, [Symbol.asyncIterator]: function () { return this; }, next: async function () { return this.i < 3 ? { value: this.i++, done: false } : { done: true }; } };
  got = [];
  for await (var v of own) { got.push(v); own.next = async function () { return { done: true }; }; }
  console.log("async next replaced mid-loop:", got.join());
  own = { i: 0, [Symbol.asyncIterator]: function () { return this; }, next: async function () { return this.i < 3 ? { value: this.i++, done: false } : { done: true }; } };
  async function* delegating() { yield* own; }
  got = [];
  for await (var v of delegating()) { got.push(v); own.next = async function () { return { done: true }; }; }
  console.log("async next replaced mid-delegation:", got.join());

  // When it is read: once the iterator is got, before any step.
  var order = [], traced = {};
  Object.defineProperty(traced, Symbol.asyncIterator, { get: function () {
    order.push("get @@asyncIterator");
    return function () {
      order.push("call @@asyncIterator");
      var i = 0, iterator = {};
      Object.defineProperty(iterator, "next", { get: function () { order.push("get next"); return async function () { order.push("call next"); return { value: i, done: i++ == 2 }; }; } });
      return iterator;
    };
  } });
  for await (var v of traced) order.push("body " + v);
  console.log("async order:", order.join(", "));

  // A `next` that is not callable fails at the first step; a `next`
  // getter that throws fails when the iterator is got.
  var noNext = { [Symbol.asyncIterator]: function () { return {}; } };
  console.log("async, no next, for await:", await attemptAsync(async function () { for await (var v of noNext) {} return "ran"; }));
  console.log("async, no next, yield*:", await attemptAsync(async function () { async function* g() { yield* noNext; } for await (var v of g()) {} return "ran"; }));
  var throwingNext = { [Symbol.asyncIterator]: function () { return { get next() { throw new RangeError("next getter"); } }; } };
  console.log("async, next getter throws, for await:", await attemptAsync(async function () { for await (var v of throwingNext) {} return "ran"; }));
  console.log("async, next getter throws, yield*:", await attemptAsync(async function () { async function* g() { yield* throwingNext; } for await (var v of g()) {} return "ran"; }));
})();
