// The statics build their result from the receiver constructor (never
// from Symbol.species), look `resolve` up once, call each element's own
// `then`, and close the iterator when a step after it fails.
var log = [];
function note() { log.push(Array.prototype.join.call(arguments, " ")); }
function kind(f) { try { f(); return "no throw"; } catch (e) { return e && e.constructor ? e.constructor.name : String(e); } }
var names = ["resolve", "reject", "withResolvers", "all", "allSettled", "any", "race"];

// --- receivers ---
names.forEach(function (name) {
  note(name, "on undefined:", kind(function () { Promise[name].call(undefined, []); }),
    "| on a non-constructor:", kind(function () { Promise[name].call(function () {}.bind ? (() => {}) : 0, []); }),
    "| on a plain object:", kind(function () { Promise[name].call({}, []); }));
});

// The receiver is constructed; species is not consulted.
var speciesReads = 0;
class Sub extends Promise {
  static get [Symbol.species]() { speciesReads += 1; return Promise; }
}
names.forEach(function (name) {
  var made = Sub[name]([]);
  var promise = name == "withResolvers" ? made.promise : made;
  if (name == "reject" || name == "any") promise.catch(function () {});
  note("Sub." + name + ":", promise instanceof Sub, promise.constructor === Sub);
});
note("species reads by the statics themselves:", speciesReads > 0 ? "only from catch()" : "none");

// A constructor throwing, and executor misuse.
function Thrower() { throw new RangeError("constructor threw"); }
function Lazy() {}
names.forEach(function (name) {
  note(name, "constructor throws:", kind(function () { Promise[name].call(Thrower, []); }), "| executor unused:", kind(function () { Promise[name].call(Lazy, []); }));
});

// --- resolve ---
var p = Promise.resolve(1);
note("resolve identity:", Promise.resolve(p) === p);
var other = Promise.resolve(1);
other.constructor = function () {};
note("resolve with another constructor wraps:", Promise.resolve(other) !== other);
var reads = [];
var observed = Promise.resolve(1);
Object.defineProperty(observed, "constructor", { get: function () { reads.push("constructor"); return Promise; } });
note("resolve reads constructor:", Promise.resolve(observed) === observed, reads.join());
var poisoned = Promise.resolve(1);
Object.defineProperty(poisoned, "constructor", { get: function () { throw new EvalError("poison"); } });
note("resolve with a throwing constructor read:", kind(function () { Promise.resolve(poisoned); }));
function Custom(executor) {
  var self = this;
  executor(function (v) { self.value = v; note("Custom resolve:", String(v)); }, function (r) { self.reason = r; note("Custom reject:", String(r)); });
}
note("custom resolve:", Promise.resolve.call(Custom, "cv") instanceof Custom);
note("custom reject:", Promise.reject.call(Custom, "cr") instanceof Custom);
var parts = Promise.withResolvers.call(Custom);
note("custom withResolvers:", parts.promise instanceof Custom, typeof parts.resolve, typeof parts.reject, Object.keys(parts).join());
parts.resolve("through the pair");
var native = Promise.withResolvers();
native.resolve("wr1"); native.reject("wr2"); native.resolve("wr3");
native.promise.then(function (v) { note("withResolvers settles once:", v); });

// --- combinators over a custom constructor ---
// Elements are resolved through the receiver's own `resolve`; here that
// hands back ordinary promises, whose settlements reach Custom's pair.
Custom.resolve = function (v) { return Promise.resolve(v); };
["all", "allSettled", "any", "race"].forEach(function (name) {
  var made = Promise[name].call(Custom, [name + " 1", { then: function (ok) { ok(name + " thenable"); } }]);
  note(name, "returned a Custom:", made instanceof Custom);
});

// `resolve` is looked up once, then called per element with the receiver.
var resolveReads = 0, resolveCalls = [];
class Tracked extends Promise {
  static get resolve() {
    resolveReads += 1;
    return function (v) { resolveCalls.push(this === Tracked ? "Tracked:" + v : "other"); return Promise.resolve.call(this, v); };
  }
}
Tracked.all([1, 2, 3]).then(function (v) { note("all values:", v.join(), "| resolve reads:", resolveReads, "| calls:", resolveCalls.join()); });
class NoResolve extends Promise {}
NoResolve.resolve = 5;
var closedBy = [];
function iterable(items) {
  var i = 0;
  var it = { next: function () { return i < items.length ? { value: items[i++], done: false } : { value: undefined, done: true }; }, "return": function () { closedBy.push("closed"); return {}; } };
  it[Symbol.iterator] = function () { return it; };
  return it;
}
NoResolve.all(iterable([1])).then(null, function (e) { note("non-callable resolve rejects:", e.constructor.name, "| iterator untouched:", closedBy.length == 0); });

// An element's `then` is invoked, and failures after the iterator step close it.
["all", "allSettled", "any", "race"].forEach(function (name) {
  closedBy = [];
  var badThen = { get then() { throw "then getter " + name; } };
  class Direct extends Promise { static resolve(v) { return v; } }
  var viaGetter = Direct[name](iterable([badThen]));
  var afterGetter = closedBy.join();
  closedBy = [];
  class Failing extends Promise { static resolve() { throw "resolve threw " + name; } }
  var viaResolve = Failing[name](iterable([1]));
  var afterResolve = closedBy.join();
  closedBy = [];
  var viaNext = Promise[name]({ [Symbol.iterator]: function () { return { next: function () { throw "next threw " + name; }, "return": function () { closedBy.push("closed"); return {}; } }; } });
  var afterNext = closedBy.join() || "not closed";
  viaGetter.then(null, function (r) { note(name, "then getter:", r, "|", afterGetter); });
  viaResolve.then(null, function (r) { note(name, "resolve:", r, "|", afterResolve); });
  viaNext.then(null, function (r) { note(name, "next:", r, "|", afterNext); });
});

// The handlers each mode passes to `then`.
["all", "allSettled", "any", "race"].forEach(function (name) {
  var seen = [];
  var fulfilledWith, rejectedWith;
  function Spy(executor) { var res, rej; executor(res = function (v) { fulfilledWith = v; }, rej = function (r) { rejectedWith = r; }); this.res = res; this.rej = rej; }
  Spy.resolve = function (v) { return v; };
  var first = { then: function (a, b) { seen.push(a); seen.push(b); } };
  var second = { then: function (a, b) { seen.push(a); seen.push(b); } };
  var made = Promise[name].call(Spy, [first, second]);
  note(name, "handlers:", "fulfill shared", seen[0] === seen[2], "| fulfill is capability's", seen[0] === made.res, "| reject shared", seen[1] === seen[3], "| reject is capability's", seen[1] === made.rej, "| lengths", seen[0].length, seen[1].length);
  // Element functions act once each; the result arrives when the last reports.
  seen[0]("a"); seen[0]("again"); seen[3]("b"); seen[3]("again");
  if (name != "race" && name != "any" && name != "all") seen[2]("late");
  note(name, "outcome:", JSON.stringify(fulfilledWith), "|", rejectedWith && rejectedWith.errors ? "AggregateError " + JSON.stringify(rejectedWith.errors) : JSON.stringify(rejectedWith));
});

// A capability whose resolve throws rejects the result instead.
function Fragile(executor) {
  return new Promise(function (_, reject) { executor(function () { throw "resolve threw"; }, reject); });
}
Fragile.resolve = Promise.resolve;
Promise.all.call(Fragile, []).then(null, function (r) { note("all, resolve throws:", r); });
Promise.allSettled.call(Fragile, []).then(null, function (r) { note("allSettled, resolve throws:", r); });

// Ordinary results and their order.
Promise.all([1, Promise.resolve(2), { then: function (ok) { ok(3); } }]).then(function (v) { note("all:", v.join()); });
Promise.allSettled([1, Promise.reject("x")]).then(function (v) { note("allSettled:", JSON.stringify(v)); });
Promise.any([Promise.reject("a"), Promise.reject("b")]).then(null, function (e) { note("any:", e.constructor.name, e.errors.join(), JSON.stringify(Object.getOwnPropertyDescriptor(e, "errors").enumerable)); });
Promise.any([Promise.reject("a"), 5]).then(function (v) { note("any value:", v); });
Promise.race([new Promise(function () {}), Promise.reject("lost"), 7]).then(null, function (r) { note("race:", r); });
Promise.all([]).then(function (v) { note("all empty:", Array.isArray(v), v.length); });
Promise.any([]).then(null, function (e) { note("any empty:", e.constructor.name, e.errors.length); });
var never = Promise.race([]);
note("race empty stays pending:", never instanceof Promise);

function settle(n, done) { if (n == 0) { done(); } else { Promise.resolve().then(function () { settle(n - 1, done); }); } }
settle(12, function () { console.log(log.join("\n")); });
