// A recursion deeper than the call stack throws a RangeError that a
// program can catch, and the engine goes on working afterwards: through
// every way a function is entered, from JavaScript and from a builtin.
//
// Every recursion here counts down from DEPTH, never without end, and the
// one that spreads an array is sized to stay small: an engine with no
// limit finishes or crashes at once, and fails the case, without using
// the machine's memory up.
var DEPTH = 100000;

function report(label, run) {
  try {
    console.log(label, "returned", run());
  } catch (e) {
    console.log(label, e instanceof RangeError, e.name + ": " + e.message);
  }
}

// --- Calls the dispatch loop makes itself.

function down(n) { return n === 0 ? 0 : down(n - 1) + 1; }
console.log("below the limit", down(1000));
report("plain call", function () { return down(DEPTH); });

function even(n) { return n === 0 ? true : odd(n - 1); }
function odd(n) { return n === 0 ? false : even(n - 1); }
report("mutual recursion", function () { return even(DEPTH); });

var counter = { walk: function (n) { return n === 0 ? 0 : this.walk(n - 1) + 1; } };
report("method call", function () { return counter.walk(DEPTH); });

function Link(n) { this.rest = n === 0 ? null : new Link(n - 1); }
report("new", function () { return new Link(DEPTH).rest === null; });

class Base { constructor(n) { this.n = n; } }
class Derived extends Base {
  constructor(n) { super(n); this.inner = n === 0 ? null : new Derived(n - 1); }
}
report("class constructor", function () { return new Derived(DEPTH).n; });

function spreadDown(n) { return n === 0 ? 0 : spreadDown(...[n - 1]) + 1; }
report("spread call", function () { return spreadDown(DEPTH); });

var closureDown = function (n) { return n === 0 ? 0 : closureDown(n - 1) + 1; };
report("closure", function () { return closureDown(DEPTH); });

// Arguments take stack too: forty levels of sixty thousand each.
var many = new Array(60000).fill(1);
function wide(n) { return n === 0 ? 0 : wide(n - 1, ...many) + 1; }
report("long argument lists", function () { return wide(40); });
console.log("one long argument list", (function () { return arguments.length; })(...many));
function wideApply(n) { return n === 0 ? 0 : wideApply.apply(null, [n - 1].concat(many)) + 1; }
report("long argument lists, apply", function () { return wideApply(40); });
function WideMade(n) { this.c = n === 0 ? 0 : Reflect.construct(WideMade, [n - 1].concat(many)).c + 1; }
report("long argument lists, construct", function () { return new WideMade(40).c; });

// --- Calls a builtin makes back into JavaScript.

var getter = { n: DEPTH, get x() { this.n = this.n - 1; return this.n === 0 ? 0 : this.x + 1; } };
report("getter", function () { return getter.x; });

var setter = { set x(n) { if (n > 0) this.x = n - 1; } };
report("setter", function () { setter.x = DEPTH; return "done"; });

function viaMap(n) { return n === 0 ? 0 : [n - 1].map(viaMap)[0] + 1; }
report("Array.prototype.map", function () { return viaMap(DEPTH); });

function viaForEach(n) { var r = 0; if (n > 0) [n - 1].forEach(function (v) { r = viaForEach(v) + 1; }); return r; }
report("Array.prototype.forEach", function () { return viaForEach(DEPTH); });

function viaSort(n) {
  var r = 0;
  if (n > 0) [2, 1].sort(function (a, b) { if (r === 0) r = viaSort(n - 1) + 1; return a - b; });
  return r;
}
report("sort comparator", function () { return viaSort(DEPTH); });

function viaApply(n) { return n === 0 ? 0 : viaApply.apply(null, [n - 1]) + 1; }
report("Function.prototype.apply", function () { return viaApply(DEPTH); });

function viaCall(n) { return n === 0 ? 0 : viaCall.call(null, n - 1) + 1; }
report("Function.prototype.call", function () { return viaCall(DEPTH); });

function viaBind(n) { return n === 0 ? 0 : viaBind.bind(null, n - 1)() + 1; }
report("bound function", function () { return viaBind(DEPTH); });

function viaReflect(n) { return n === 0 ? 0 : Reflect.apply(viaReflect, null, [n - 1]) + 1; }
report("Reflect.apply", function () { return viaReflect(DEPTH); });

function Made(n) { this.c = n === 0 ? 0 : Reflect.construct(Made, [n - 1]).c + 1; }
report("Reflect.construct", function () { return new Made(DEPTH).c; });

var conversions = 0;
var converted = { valueOf: function () { conversions = conversions + 1; return conversions >= DEPTH ? 0 : converted + 1; } };
report("valueOf", function () { return converted + 0; });

var texts = 0;
var text = { toString: function () { texts = texts + 1; return texts >= DEPTH ? "0" : "" + text; } };
report("toString", function () { return String(text); });

function viaJSON(n) { return n === 0 ? 0 : JSON.parse(JSON.stringify({ toJSON: function () { return viaJSON(n - 1) + 1; } })); }
report("toJSON", function () { return viaJSON(DEPTH); });

function viaReplace(n) { return n === 0 ? 0 : Number("a".replace(/a/, function () { return String(viaReplace(n - 1) + 1); })); }
report("replace callback", function () { return viaReplace(DEPTH); });

function viaEval(n) { return n === 0 ? 0 : eval("viaEval(n - 1)") + 1; }
report("eval", function () { return viaEval(DEPTH); });

function viaIterator(n) {
  if (n === 0) return 0;
  var source = {};
  source[Symbol.iterator] = function () {
    var done = false;
    return { next: function () { if (done) return { done: true }; done = true; return { value: viaIterator(n - 1) + 1, done: false }; } };
  };
  var r = 0;
  for (var v of source) r = v;
  return r;
}
report("iterator", function () { return viaIterator(DEPTH); });

// --- Generators and async functions.

function* nest(n) { if (n > 0) yield* nest(n - 1); yield n; }
report("generator delegation", function () { var seen = 0; for (var v of nest(DEPTH)) seen = seen + 1; return seen; });

function* startDown(n) { yield n === 0 ? 0 : startDown(n - 1).next().value + 1; }
report("generator resumed", function () { return startDown(DEPTH).next().value; });

// An async function called where there is no room fails like any other
// call, with a throw from the call or with a rejected promise, as the
// engine has it: a try around the await sees either.
async function awaitDown(n) {
  if (n === 0) return "bottom";
  try { return await awaitDown(n - 1); } catch (e) { return e.name; }
}
awaitDown(DEPTH).then(function (v) { console.log("async function", v); });

// One that awaits before it calls itself runs each call from a job, on
// an empty stack: as deep as it likes.
async function jobDown(n) { await null; return n === 0 ? 0 : (await jobDown(n - 1)) + 1; }
jobDown(5000).then(function (v) { console.log("async function, a job a call", v); });

// --- After the error.

// Every finally on the way out runs.
var finals = 0;
function unwinding(n) { try { return n === 0 ? 0 : unwinding(n - 1) + 1; } finally { finals = finals + 1; } }
report("try/finally", function () { return unwinding(DEPTH); });
console.log("finally blocks ran", finals > 1000);

// Caught where it happens, deep in the recursion, and the frames above
// return as usual.
function recover(n) {
  if (n === 0) return "bottom";
  try { return recover(n - 1); } catch (e) { return e instanceof RangeError ? "recovered" : "other"; }
}
console.log("caught at depth", recover(DEPTH));

// It happens again each time, and everything else still works.
report("again", function () { return down(DEPTH); });
report("and again", function () { return getter.x; });
console.log("below the limit", down(1000), even(1000), counter.walk(500), viaMap(200), spreadDown(300));
var squares = [];
for (var i = 0; i < 5; i++) squares.push((function (k) { return function () { return k * k; }; })(i));
console.log(squares.map(function (f) { return f(); }).join(), JSON.stringify({ a: [1, { b: 2 }] }), "x".repeat(3));
function* three() { yield 1; yield 2; yield 3; }
console.log(Array.from(three()).join(), new Derived(2).inner.inner.inner);
