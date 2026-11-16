// What an iteration reads, and when: an iterable's Symbol.iterator once,
// and its iterator's `next` once, when the iterator is got, however many
// steps follow; and Array.from calling its mapping function on each value
// as that value is produced.

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
