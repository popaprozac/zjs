// Forced collections in every place the promise machinery hands control
// to the program: constructors, getters, executors, handlers, element
// functions, iterators. After each one the freed cells are reused at
// once, so a value the engine failed to keep alive shows up as damage.
var log = [];
function note() { log.push(Array.prototype.join.call(arguments, " ")); }
function churn() {
  var keep = [];
  for (var i = 0; i < 400; i++) { keep.push({ a: i, b: [i, i + 1], c: function () { return i; }, d: "s" + i }); }
  return keep.length;
}
function collect() { gc(); churn(); gc(); churn(); }

// A constructor, its executor call, and the functions it passes.
function Collecting(executor) {
  collect();
  var self = this;
  executor(function (v) { collect(); self.value = v; note("Collecting resolve:", JSON.stringify(v)); }, function (r) { collect(); self.reason = r; note("Collecting reject:", String(r)); });
  collect();
}
Object.defineProperty(Collecting, Symbol.species, { get: function () { collect(); return Collecting; } });
Collecting.resolve = function (v) { collect(); return Promise.resolve(v); };
Collecting.prototype.then = function (onFulfilled) { collect(); note("Collecting then:", typeof onFulfilled, arguments.length); return this; };

function source(value) {
  var p = Promise.resolve(value);
  Object.defineProperty(p, "constructor", { get: function () { collect(); return Collecting; } });
  return p;
}
source({ tag: "then" }).then(function (v) { collect(); return { from: v.tag, list: [1, 2, 3] }; });
source("pass").then();
source("finally").finally(function () { collect(); return { ignored: true }; });
Promise.reject(new Error("boom")).catch(function (e) { collect(); return e.message; }).then(function (m) { note("catch:", m); });

// Statics over the collecting constructor, with an iterator that collects.
function items(list) {
  var i = 0;
  var it = { next: function () { collect(); return i < list.length ? { value: list[i++], done: false } : { value: undefined, done: true }; } };
  it[Symbol.iterator] = function () { collect(); return it; };
  return it;
}
var thenable = { get then() { collect(); return function (ok) { collect(); ok({ thenable: true }); }; } };
["all", "allSettled", "any", "race"].forEach(function (name) {
  Promise[name].call(Collecting, items([{ n: name }, thenable, Promise.resolve([name])]));
});
var parts = Promise.withResolvers.call(Collecting);
collect();
parts.resolve({ parts: true });
Promise.reject.call(Collecting, "static reject");

// Subclass chains, with collections in the constructor and in handlers.
class Sub extends Promise {
  constructor(executor) { collect(); super(function (resolve, reject) { collect(); executor(resolve, reject); }); collect(); }
}
Sub.resolve({ start: 1 })
  .then(function (v) { collect(); return new Sub(function (resolve) { collect(); resolve({ next: v.start + 1 }); }); })
  .finally(function () { collect(); })
  .then(function (v) { collect(); note("subclass chain:", JSON.stringify(v)); return Sub.all([v, Sub.resolve("x")]); })
  .then(function (v) { note("subclass all:", JSON.stringify(v)); });

// Async bodies awaiting promises whose constructor read collects.
async function body() {
  var held = { kept: [1, 2, 3] };
  var p = Promise.resolve({ awaited: true });
  Object.defineProperty(p, "constructor", { get: function () { collect(); return Promise; } });
  var v = await p;
  collect();
  return JSON.stringify(v) + JSON.stringify(held);
}
body().then(function (v) { note("async body:", v); });

function settle(n, done) { if (n == 0) { done(); } else { Promise.resolve().then(function () { collect(); settle(n - 1, done); }); } }
settle(14, function () { console.log(log.join("\n")); });
