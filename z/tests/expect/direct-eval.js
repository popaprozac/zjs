// A direct eval runs in the scope of its call: it reads and writes the
// calling function's bindings (and those of the functions around it),
// sees its `this` and `arguments`, and a sloppy one's var and function
// declarations become bindings of the calling function.
function reassign() {
  function h(v) { return v + 1; }
  eval("h = function (v) { return -v; }");
  return h(3);
}
console.log(reassign());

function reads(a) {
  var b = 2;
  let c = 3;
  { let c = 30; return eval("a + b + c"); }
}
console.log(reads(1));

function writesOuter() {
  var hits = 0;
  function bump() { eval("hits++"); }
  bump();
  bump();
  return hits;
}
console.log(writesOuter());

let counter = 0;
function bumpTop() { eval("counter += 10"); }
bumpTop();
console.log(counter, eval("counter + 1"));

// A sloppy eval's var and function declarations stay in the function,
// visible to its code and closures before and after, and to later evals.
var shadowed = "global";
function declares() {
  const early = () => shadowed;
  const before = early();
  eval("var shadowed = 'local'; var fresh = 1; function added(n) { return fresh + n; }");
  eval("fresh += 1");
  return [before, early(), shadowed, typeof fresh, added(5)].join(" ");
}
console.log(declares(), shadowed, typeof fresh, typeof added);

function reusesParameter(p) {
  eval("var p = p * 2");
  return p;
}
console.log(reusesParameter(21));

// A strict eval keeps its declarations; a let never leaves the eval.
function strictDeclares() {
  "use strict";
  eval("var inner = 1");
  return typeof inner;
}
function keepsLet() {
  eval("let inner = 1");
  return typeof inner;
}
console.log(strictDeclares(), keepsLet(), eval("let k = 7; () => k")());

// Errors: an uninitialized binding, a constant, and a var over a lexical
// binding of the function.
function errors() {
  const out = [];
  try { eval("later"); } catch (e) { out.push(e.name); }
  let later = 1;
  const fixed = 1;
  try { eval("fixed = 2"); } catch (e) { out.push(e.name); }
  try { eval("var later = 2"); } catch (e) { out.push(e.name); }
  function inParameters(a, b = eval("var a")) {}
  try { inParameters(); } catch (e) { out.push(e.name); }
  return out.join(" ") + " " + later + " " + fixed;
}
console.log(errors());

// A named function expression's own name is immutable: sloppy code's
// assignment, eval code's included, leaves it, strict code's throws; a
// parameter or var of the name shadows it.
const named = function inner() { inner = 1; eval("inner = 2"); return inner === named; };
const strictNamed = function inner() { "use strict"; try { eval("inner = 1"); } catch (e) { return e.name; } };
const parameterNamed = function inner(inner) { eval("inner = inner * 2"); return inner; };
console.log(named(), strictNamed(), parameterNamed(21));

// `this`, `arguments`, nesting, and eval called another way.
const holder = { tag: "T", read() { return eval("this.tag"); } };
console.log(holder.read(), (function () { return eval("arguments.length"); })(1, 2, 3));
function arrowArguments() { return (() => eval("arguments[0]"))(); }
console.log(arrowArguments("first"));
class Base {}
class Derived extends Base { constructor() { super(); this.self = eval("this"); } }
console.log(new Derived().self instanceof Derived);
function nested() { eval("eval('var deep = 4')"); return deep; }
console.log(nested());
function* generator() { var x = 1; yield eval("x + 1"); x = 5; yield eval("x"); }
console.log([...generator()].join());
function indirect() { var local = 1; return (0, eval)("typeof local"); }
function renamed() { var eval = (s) => "not the intrinsic: " + s; return eval("1"); }
console.log(indirect(), renamed());
for (let i = 0; i < 2; i++) console.log("iteration", eval("i"));
