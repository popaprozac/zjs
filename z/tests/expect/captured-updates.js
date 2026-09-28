// `x += e` on a captured binding is one instruction, and `return x` just
// after it returns the register the sum is in; neither may change what
// the program sees.
var out = [];
function show() { out.push(Array.prototype.join.call(arguments, " ")); }

function counter(start) { var n = start; return function (step) { n += step; return n; }; }
var c = counter(10);
show(c(1), c(2), c(-3), c("x"), c(1));

// A jump lands on the return: it must read the binding, not the register.
function maybe() { var n = 0; return function (add) { if (add) n += 5; return n; }; }
var m = maybe();
show(m(true), m(false), m(true));
function loopy() { var n = 0; return function () { for (var i = 0; i < 3; i++) n += i; return n; }; }
show(loopy()(), loopy()());

// Plain stores, several levels out, strings, and the order of coercions.
function nest() {
  var total = 0;
  return function () { return function (v) { total += v; return total; }; };
}
var inner = nest()();
show(inner(1), inner(2));
function assign() { var s = "a"; return function (t) { s = s + t; return s; }; }
var a = assign();
show(a("b"), a("c"));
function order() {
  var n = 1;
  var tricky = { valueOf: function () { n = 100; return 5; } };
  return function () { n += tricky; return n; };
}
show(order()());

// Checked bindings keep their checks: a let before its declaration, a const.
function early() { var f = function () { v += 1; return v; }; try { f(); } catch (e) { show(e.constructor.name); } let v = 1; show(f()); }
early();
function constant() { const k = 1; var f = function () { k += 1; return k; }; try { f(); } catch (e) { show(e.constructor.name); } }
constant();

// Per-iteration bindings, try/finally, and generators.
var fns = [];
for (let i = 0; i < 3; i++) fns.push(function () { i += 10; return i; });
show(fns.map(function (f) { return f(); }).join(","));
function withFinally() { var n = 0; return function () { try { n += 1; return n; } finally { n += 100; } }; }
var wf = withFinally();
show(wf(), wf());
function* gen() { var n = 0; var add = function (k) { n += k; return n; }; yield add(1); yield add(2); }
show(Array.from(gen()).join(","));
console.log(out.join("\n"));
