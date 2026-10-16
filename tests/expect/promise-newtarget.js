// Promise constructed with a bound function as new target, whose
// `prototype` the program defined as an accessor: the read happens after
// the executor check and before anything else, its throw propagates, and
// collections forced inside the getter and the executor damage nothing.
var log = [];
function note() { log.push(Array.prototype.join.call(arguments, " ")); }
function kind(f) { try { f(); return "no throw"; } catch (e) { return e && e.constructor ? e.constructor.name : String(e); } }
function churn() { var keep = []; for (var i = 0; i < 300; i++) { keep.push({ a: i, b: [i], c: "s" + i }); } return keep.length; }
function collect() { gc(); churn(); gc(); churn(); }

function boundTarget(getter) {
  var bound = (function () {}).bind();
  Object.defineProperty(bound, "prototype", { get: getter, configurable: true });
  return bound;
}
var reads = 0, ran = 0;
var throwing = boundTarget(function () { reads += 1; collect(); throw new RangeError("prototype getter"); });
note("getter throw propagates:", kind(function () { Reflect.construct(Promise, [function () { ran += 1; }], throwing); }), "| reads", reads, "| executor ran", ran);
reads = 0;
note("missing executor is reported first:", kind(function () { Reflect.construct(Promise, [], throwing); }), "| reads", reads);
note("non-callable executor is reported first:", kind(function () { Reflect.construct(Promise, [{}], throwing); }), "| reads", reads);

// A getter that answers: the promise takes that prototype, read once,
// before the executor runs.
var custom = { marker: "custom" };
var order = [];
var answering = boundTarget(function () { order.push("prototype"); collect(); return custom; });
var made = Reflect.construct(Promise, [function (resolve) { order.push("executor"); collect(); resolve({ v: 1 }); }], answering);
note("prototype from the getter:", Object.getPrototypeOf(made) === custom, "|", order.join());
Promise.prototype.then.call(made, function (v) { collect(); note("settles normally:", JSON.stringify(v)); });
var primitive = boundTarget(function () { return 7; });
note("non-object prototype falls back:", Object.getPrototypeOf(Reflect.construct(Promise, [function () {}], primitive)) === Promise.prototype);
note("plain bound new target, no prototype at all:", Object.getPrototypeOf(Reflect.construct(Promise, [function () {}], (function () {}).bind())) === Promise.prototype);

// Through a bound Promise: constructing it constructs Promise, with
// Promise as new target unless another was given.
var BoundPromise = Promise.bind();
var viaBound = new BoundPromise(function (resolve) { collect(); resolve("bp"); });
note("new bound Promise:", viaBound instanceof Promise, viaBound instanceof BoundPromise, Object.getPrototypeOf(viaBound) === Promise.prototype);
note("bound Promise called:", kind(function () { BoundPromise(function () {}); }));
reads = 0;
note("bound Promise with the throwing new target:", kind(function () { Reflect.construct(BoundPromise, [function () {}], throwing); }), "| reads", reads);
reads = 0;
note("and a bad executor still first:", kind(function () { Reflect.construct(BoundPromise, [5], throwing); }), "| reads", reads);
var viaAnswering = Reflect.construct(BoundPromise, [function (resolve) { resolve("x"); }], answering);
note("bound Promise, answering new target:", Object.getPrototypeOf(viaAnswering) === custom);
var Twice = BoundPromise.bind();
var viaTwice = new Twice(function (resolve) { resolve("twice"); });
note("bound twice:", viaTwice instanceof Promise, Object.getPrototypeOf(viaTwice) === Promise.prototype);

// A subclass, bound: super() reaches Promise with the subclass as new target.
class Sub extends Promise { constructor(executor) { collect(); super(executor); this.tag = "sub"; } }
var BoundSub = Sub.bind();
var sub = new BoundSub(function (resolve) { resolve("s"); });
note("bound subclass:", sub instanceof Sub, sub.tag, Object.getPrototypeOf(sub) === Sub.prototype, Object.getPrototypeOf(BoundSub) === Promise);
sub.then(function (v) { note("bound subclass settles:", v, "| then result is a Sub:", sub.then() instanceof Sub); });

// As the receiver of the statics, a bound Promise is a constructor like any other.
BoundPromise.resolve = Promise.resolve;
var resolved = Promise.resolve.call(BoundPromise, "static");
note("static resolve through a bound constructor:", resolved instanceof Promise);
Promise.all.call(BoundPromise, [1, viaBound]).then(function (v) { note("all through a bound constructor:", v.join()); });

function settle(n, done) { if (n == 0) { done(); } else { Promise.resolve().then(function () { settle(n - 1, done); }); } }
settle(8, function () { console.log(log.join("\n")); });
