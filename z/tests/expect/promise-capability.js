// Promise construction and constructor-made capabilities: what the
// constructor checks and in which order, and that a capability built by
// a constructor the program supplies is reached only through the two
// functions that constructor passed, whatever object it returned.
var log = [];
function note() { log.push(Array.prototype.join.call(arguments, " ")); }
function kind(f) { try { f(); return "no throw"; } catch (e) { return e && e.constructor ? e.constructor.name : String(e); } }

// --- the constructor itself ---
note("call without new:", kind(function () { Promise(function () {}); }));
note("call on null:", kind(function () { Promise.call(null, function () {}); }));
var existing = new Promise(function () {});
note("call on a promise:", kind(function () { Promise.call(existing, function () {}); }));
note("call on a plain object:", kind(function () { Promise.call({}, function () {}); }));
note("executor missing:", kind(function () { new Promise(); }));
note("executor not callable:", kind(function () { new Promise({}); }));

// The executor is checked before the new target's prototype is read.
var reads = [];
function Target() {}
var customProto = { marker: "custom" };
Target.prototype = customProto;
var made = Reflect.construct(Promise, [function () { reads.push("executor"); }], Target);
note("prototype from new target:", Object.getPrototypeOf(made) === customProto, made instanceof Promise, reads.join());
note("still a promise:", kind(function () { Promise.prototype.then.call(made, function () {}); }));
function Primitive() {}
Primitive.prototype = 7;
note("non-object prototype falls back:", Object.getPrototypeOf(Reflect.construct(Promise, [function () {}], Primitive)) === Promise.prototype);
note("bad executor with custom target:", kind(function () { Reflect.construct(Promise, [1], Target); }));

// The executor's throw rejects; a throw after resolution is ignored.
new Promise(function () { throw "thrown early"; }).then(null, function (r) { note("executor throw ->", r); });
new Promise(function (resolve) { resolve("kept"); throw "ignored"; }).then(function (v) { note("resolve then throw ->", v); });
new Promise(function (resolve, reject) { resolve("first"); resolve("second"); reject("third"); }).then(function (v) { note("repeated settlement ->", v); });
new Promise(function (resolve, reject) { reject("r1"); resolve("r2"); }).then(null, function (r) { note("reject wins ->", r); });

// Resolving functions.
var fns;
new Promise(function (resolve, reject) { fns = [resolve, reject]; });
note("resolving functions:", fns[0].length, fns[1].length, JSON.stringify(fns[0].name), JSON.stringify(fns[1].name), fns[0] !== fns[1]);
note("not constructors:", kind(function () { new fns[0](); }), Object.prototype.hasOwnProperty.call(fns[0], "prototype"));

// Self resolution and thenable assimilation.
var selfResolve;
var self = new Promise(function (resolve) { selfResolve = resolve; });
selfResolve(self);
self.then(null, function (e) { note("self resolution ->", e.constructor.name); });
var thenReads = 0;
var thenable = { get then() { thenReads += 1; return function (ok) { note("thenable.then called, reads", thenReads); ok("assimilated"); ok("again"); throw "late"; }; } };
Promise.resolve(thenable).then(function (v) { note("thenable ->", v); });
var poisoned = { get then() { throw "then getter"; } };
Promise.resolve(poisoned).then(null, function (r) { note("poisoned then ->", r); });

// --- capabilities made through a constructor ---
var executorSeen;
function NotPromise(executor) {
  executorSeen = executor;
  executor(function (v) { note("custom resolve got", v); }, function (r) { note("custom reject got", r); });
  this.custom = true;
}
var source = Promise.resolve("value");
source.constructor = NotPromise;
NotPromise[Symbol.species] = NotPromise;
var derived = source.then(function (v) { return v + "!"; });
note("then returns the constructor's object:", derived instanceof NotPromise, derived.custom, derived instanceof Promise);
note("executor function:", executorSeen.length, JSON.stringify(executorSeen.name), Object.isExtensible(executorSeen), Object.prototype.hasOwnProperty.call(executorSeen, "prototype"), kind(function () { new executorSeen(); }));
var rejecting = Promise.reject("reason");
rejecting.constructor = NotPromise;
rejecting.then();
var throwing = Promise.resolve(1);
throwing.constructor = NotPromise;
throwing.then(function () { throw "handler threw"; });

// Malformed executors.
function trial(label, body) {
  var p = Promise.resolve(0);
  function C(executor) { body(executor); }
  C[Symbol.species] = C;
  p.constructor = C;
  note(label, kind(function () { p.then(); }));
}
trial("executor never called:", function () {});
trial("called with nothing:", function (ex) { ex(); });
trial("resolve only:", function (ex) { ex(function () {}, undefined); });
trial("reject only:", function (ex) { ex(undefined, function () {}); });
trial("non-callable pair:", function (ex) { ex(1, 2); });
trial("twice, nothing first:", function (ex) { ex(); ex(function () {}, function () {}); });
trial("twice, functions first:", function (ex) { ex(function () {}, function () {}); ex(function () {}, function () {}); });
trial("twice, resolve first:", function (ex) { ex(function () {}, undefined); ex(undefined, function () {}); });
trial("constructor throws:", function () { throw new RangeError("from constructor"); });
trial("executor error is the caller's:", function (ex) { ex(function () {}, function () {}); try { ex(function () {}, function () {}); } catch (e) { note("second call threw", e.constructor.name); } });

// A capability's functions may throw; the job drops it and later jobs run.
function Throwing(executor) { executor(function () { note("throwing resolve called"); throw "from resolve"; }, function () {}); }
Throwing[Symbol.species] = Throwing;
var t = Promise.resolve(1);
t.constructor = Throwing;
t.then();

Promise.resolve().then(function () {}).then(function () {}).then(function () {}).then(function () { console.log(log.join("\n")); });
