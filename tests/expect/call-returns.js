// Returns: an ordinary call's frame is popped field by field; a
// constructor, a generator, or an async function takes the full path.
function id(x) { return x; }
function add(a, b) { return a + b; }
function nested(n) { return n === 0 ? 0 : 1 + nested(n - 1); }
console.log(id(1), add(2, 3), nested(50));

// The caller's `this` is back after the callee returns.
var holder = {
  name: "holder",
  outer: function () { var inner = id(this.name); return this.name + ":" + inner; },
};
console.log(holder.outer());
function sloppyThis() { return typeof this; }
function strictThis() { "use strict"; return typeof this; }
console.log(sloppyThis(), strictThis());
var arrow = { v: 7, make: function () { return () => this.v; } };
console.log(arrow.make()());

// A return from inside try and finally drops the frame's handlers.
function fromTry() { try { return "try"; } finally { log.push("finally"); } }
var log = [];
function afterReturns() {
  var got = fromTry();
  try { throw new Error("caught"); } catch (e) { return got + " " + e.message; }
}
console.log(afterReturns(), log.join(","));
function throwsLater() { id(1); throw new TypeError("late"); }
try { throwsLater(); } catch (e) { console.log(e.constructor.name, e.message); }

// Constructors: an object result wins, a primitive does not.
function Point(x) { this.x = x; return 5; }
function Boxed(x) { this.x = x; return { boxed: x }; }
class Base { constructor(v) { this.v = v; } }
class Derived extends Base { constructor(v) { super(v * 2); } }
console.log(new Point(1).x, new Boxed(2).boxed, new Derived(3).v);

// Generators and async functions finish through their own path.
function* counter() { yield 1; return 2; }
var g = counter();
console.log(JSON.stringify([g.next(), g.next(), g.next()]));
async function later(x) { return x + 1; }
later(1).then(function (v) { console.log("async", v); });

// Callbacks return to the builtin that called them.
console.log([1, 2, 3].map(function (x) { return x * 10; }).join(","));
console.log([3, 1, 2].sort(function (a, b) { return a - b; }).join(","));
console.log([1, 2, 3, 4].reduce(function (s, x) { return s + id(x); }, 0));

// Many returns with allocation between them.
var kept = [];
function make(i) { return { i: i, s: "v" + i }; }
for (var i = 0; i < 20000; i++) kept.push(make(i));
console.log(kept.length, kept[19999].s);
