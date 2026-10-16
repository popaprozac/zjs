// then / catch / finally through the receiver's species: which reads
// happen and in what order, what each invalid species does, and that the
// promises the engine makes for await and async bodies stay its own.
var log = [];
function note() { log.push(Array.prototype.join.call(arguments, " ")); }
function kind(f) { try { f(); return "no throw"; } catch (e) { return e && e.constructor ? e.constructor.name : String(e); } }

// --- subclasses ---
var constructed = 0;
class Sub extends Promise {
  constructor(executor) { constructed += 1; super(executor); }
}
var sub = new Sub(function (resolve) { resolve(1); });
note("subclass instance:", constructed, sub instanceof Sub, sub.constructor === Sub);
constructed = 0;
var viaThen = sub.then(function (v) { return v + 1; });
note("then:", constructed, viaThen instanceof Sub);
constructed = 0;
var viaCatch = sub.catch(function () {});
note("catch:", constructed, viaCatch instanceof Sub);
constructed = 0;
var viaFinally = sub.finally(function () {});
note("finally:", constructed, viaFinally instanceof Sub);
viaThen.then(function (v) { note("subclass chain value", v); });

// Species may redirect a subclass to the intrinsic constructor.
class Plain extends Promise { static get [Symbol.species]() { return Promise; } }
var plain = new Plain(function (resolve) { resolve(2); }).then(function (v) { return v; });
note("species -> Promise:", plain instanceof Plain, plain instanceof Promise);

// --- the reads then() makes, in order ---
var trace = [];
var watched = Promise.resolve("w");
Object.defineProperty(watched, "constructor", { get: function () { trace.push("get constructor"); return Watched; } });
function Watched(executor) { trace.push("construct"); return new Promise(executor); }
Object.defineProperty(Watched, Symbol.species, { get: function () { trace.push("get species"); return Watched; } });
watched.then(function () {});
note("then reads:", trace.join(", "));
trace = [];
watched.finally(function () {});
note("finally reads:", trace.join(", "));
trace = [];
watched.catch(function () {});
note("catch reads:", trace.join(", "));

// --- invalid species ---
function withSpecies(value) {
  var p = Promise.resolve(0);
  var C = function () {};
  C[Symbol.species] = value;
  p.constructor = C;
  return p;
}
note("species undefined:", kind(function () { note("  default used:", withSpecies(undefined).then() instanceof Promise); }));
note("species null:", kind(function () { note("  default used:", withSpecies(null).then() instanceof Promise); }));
note("species number:", kind(function () { withSpecies(1).then(); }));
note("species plain object:", kind(function () { withSpecies({}).then(); }));
note("species arrow:", kind(function () { withSpecies(function () {}.bind ? (() => {}) : 0).then(); }));
var poisonedSpecies = Promise.resolve(0);
var PoisonC = function () {};
Object.defineProperty(PoisonC, Symbol.species, { get: function () { throw new RangeError("species getter"); } });
poisonedSpecies.constructor = PoisonC;
note("species getter throws:", kind(function () { poisonedSpecies.then(); }), kind(function () { poisonedSpecies.finally(); }));
var ctorUndefined = Promise.resolve(0);
ctorUndefined.constructor = undefined;
note("constructor undefined:", ctorUndefined.then() instanceof Promise);
var ctorNull = Promise.resolve(0);
ctorNull.constructor = null;
note("constructor null:", kind(function () { ctorNull.then(); }));
var ctorNumber = Promise.resolve(0);
ctorNumber.constructor = 5;
note("constructor number:", kind(function () { ctorNumber.then(); }));
var ctorPoison = Promise.resolve(0);
Object.defineProperty(ctorPoison, "constructor", { get: function () { throw new EvalError("constructor getter"); } });
note("constructor getter throws:", kind(function () { ctorPoison.then(); }), kind(function () { ctorPoison.finally(); }));
note("then on a non-promise:", kind(function () { Promise.prototype.then.call({ constructor: Promise }, function () {}); }));
note("finally on a non-object:", kind(function () { Promise.prototype.finally.call(3); }));

// --- catch and finally go through this.then ---
var thenCalls = [];
var fake = { then: function (a, b) { thenCalls.push([typeof a, typeof b].join("/")); return "then result"; } };
note("catch forwards:", Promise.prototype.catch.call(fake, function () {}), thenCalls.join());
thenCalls = [];
note("finally forwards:", Promise.prototype.finally.call(fake, function () {}), thenCalls.join());
thenCalls = [];
note("finally, non-callable passes through:", Promise.prototype.finally.call(fake, 7), thenCalls.join());
var overridden = Promise.resolve("o");
overridden.then = function (a, b) { note("own then called with", typeof a, typeof b); return Promise.prototype.then.call(this, a, b); };
overridden.catch(function () {});
overridden.finally(function () { note("onFinally ran"); });

// finally resolves onFinally's result through the species constructor
// and calls that promise's then.
var finallyTrace = [];
class Counted extends Promise {
  constructor(executor) { finallyTrace.push("construct"); super(executor); }
  then(a, b) { finallyTrace.push("then"); return super.then(a, b); }
  static resolve(v) { finallyTrace.push("resolve"); return super.resolve(v); }
}
var counted = new Counted(function (resolve) { resolve("c"); });
finallyTrace = [];
counted.finally(function () { finallyTrace.push("onFinally"); return "ignored"; }).then(function (v) {
  note("finally passes value:", v, "| trace:", finallyTrace.join(","));
});
Promise.reject("why").finally(function () { return "ignored"; }).then(null, function (r) { note("finally passes reason:", r); });
Promise.resolve("x").finally(function () { throw "finally threw"; }).then(null, function (r) { note("finally throw replaces:", r); });
Promise.resolve("x").finally(function () { return Promise.reject("finally rejected"); }).then(null, function (r) { note("finally rejection replaces:", r); });

// --- await and async bodies keep the engine's own promises ---
var awaitTrace = [];
class Loud extends Promise {
  constructor(executor) { awaitTrace.push("Loud construct"); super(executor); }
  then(a, b) { awaitTrace.push("Loud then"); return super.then(a, b); }
}
var loud = new Loud(function (resolve) { resolve("loud"); });
awaitTrace = [];
async function body() {
  var v = await loud;
  awaitTrace.push("awaited " + v);
  return loud;
}
var result = body();
note("async result is intrinsic:", result.constructor === Promise, result instanceof Loud);
result.then(function (v) { note("await trace:", awaitTrace.join(", "), "| value", v); });
var nativeAwaited = Promise.resolve("n");
Object.defineProperty(nativeAwaited, "constructor", { get: function () { awaitTrace.push("constructor read"); return Promise; } });
nativeAwaited.then = function () { awaitTrace.push("own then must not run"); };
(async function () { awaitTrace.push("got " + (await nativeAwaited)); })();
var throwingCtor = Promise.resolve("t");
Object.defineProperty(throwingCtor, "constructor", { get: function () { throw new URIError("await constructor"); } });
(async function () {
  try { await throwingCtor; note("await did not throw"); } catch (e) { note("await threw at the await:", e.constructor.name); }
})();
(async function* () { try { yield throwingCtor; } catch (e) { note("yield threw at the yield:", e.constructor.name); } })().next();

// --- Promise[Symbol.species] itself replaced, redefined, deleted, restored ---
var speciesDescriptor = Object.getOwnPropertyDescriptor(Promise, Symbol.species);
var intrinsicReads = 0;
Object.defineProperty(Promise, Symbol.species, { get: function () { intrinsicReads += 1; return speciesDescriptor.get.call(this); }, configurable: true });
var afterReplace = Promise.resolve(1).then(function () {});
note("replaced getter is read by then:", intrinsicReads, afterReplace instanceof Promise);
Promise.resolve(1).finally(function () {});
note("and by finally:", intrinsicReads);
var elsewhereCalls = 0;
var ElsewhereCounting = function (executor) { elsewhereCalls += 1; return new Promise(executor); };
Object.defineProperty(Promise, Symbol.species, { value: ElsewhereCounting, configurable: true });
Promise.resolve(1).then(function () {});
note("data-property species is used:", elsewhereCalls);
Object.defineProperty(Promise, Symbol.species, { value: 3, configurable: true });
note("invalid species on Promise:", kind(function () { Promise.resolve(1).then(); }));
delete Promise[Symbol.species];
note("deleted species falls back:", Promise.resolve(1).then() instanceof Promise, Symbol.species in Promise);
Object.defineProperty(Promise, Symbol.species, speciesDescriptor);
note("restored:", Promise[Symbol.species] === Promise, Promise.resolve(1).then() instanceof Promise);

function settle(n, done) { if (n == 0) { done(); } else { Promise.resolve().then(function () { settle(n - 1, done); }); } }
settle(12, function () { console.log(log.join("\n")); });
