// A call to a small function declared in a function body, never written,
// is compiled in place: every case here must behave as the call would.
var out = [];
function show() { var p = []; for (var i = 0; i < arguments.length; i++) p.push(Object.is(arguments[i], -0) ? "-0" : String(arguments[i])); out.push(p.join(" ")); }

function plain() {
  function sq(x) { return x * x; }
  function clamp(x, low, high) { return x < low ? low : x > high ? high : x; }
  function pick(o) { return o.a + o["b"]; }
  function neg(x) { return -x; }
  function both(a, b) { return a && b || !a; }
  show(sq(7), sq(-0), sq("3"), sq(), clamp(5, 1, 3), clamp(-2, 0, 9), clamp(4, 0, 9));
  show(pick({ a: 1, b: 2 }), neg(0), neg("2"), both(1, 0), both(0, 1));
  // Arguments: in order, each once, extra ones still evaluated, missing ones undefined.
  var log = [];
  function note(v) { log.push(v); return v; }
  show(clamp(note(10), note(0), note(5), note(99)), sq(), log.join(","));
  var x = 2;
  show(sq(x, x = 5), x, sq(x++), x);
  // Hoisted: called before its declaration.
  show(later(4));
  function later(v) { return v + 1; }
  // Still a function value for every other use.
  show(typeof sq, sq.name, sq.length, [1, 2, 3].map(sq).join("|"));
}
plain();

function getters() {
  function width(p) { return p.w; }
  var reads = 0;
  var box = { get w() { reads++; return 3; } };
  show(width(box) + width(box), reads);
  try { width(undefined); } catch (e) { show(e.constructor.name); }
  try { width(null); } catch (e) { show(e.constructor.name); }
}
getters();

function nested() {
  function twice(v) { return v * 2; }
  var inner = function (k) { return twice(k) + 1; };
  var arrow = (k) => twice(twice(k));
  show(inner(5), arrow(3));
}
nested();

// Written or redeclared: called, not compiled in place.
function reassigned() {
  function f(v) { return v + 1; }
  var before = f(1);
  f = function (v) { return v * 100; };
  show(before, f(1));
}
reassigned();
function redeclared() {
  function g(v) { return v + 1; }
  function g(v) { return v + 2; }
  show(g(1));
}
redeclared();
function blockFunction() {
  function k(v) { return v + 1; }
  if (true) { function k(v) { return v + 50; } }
  show(k(1));
}
blockFunction();
function updated() {
  function u(v) { return v; }
  var n = 0;
  for (u in { a: 1 }) n++;
  show(typeof u, n);
}
updated();

// Not eligible: free variables, this, arguments, defaults, recursion.
function ineligible() {
  var base = 10;
  function addBase(v) { return v + base; }
  function args() { return arguments.length; }
  function dflt(v = 4) { return v; }
  function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }
  function self() { return this === undefined; }
  base = 20;
  show(addBase(1), args(1, 2, 3), dflt(), fact(5), typeof self());
}
ineligible();

// Many calls in a loop, with allocation between them.
function loop() {
  function area(r) { return r.w * r.h; }
  var total = 0;
  for (var i = 0; i < 50000; i++) total = (total + area({ w: i % 7, h: 3 })) | 0;
  show(total);
}
loop();
console.log(out.join("\n"));
