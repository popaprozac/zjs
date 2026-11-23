// `super.x` is an early error wherever no home object is in reach: in a
// script, a function, or the arrows, computed keys and property values
// written in one. A method, accessor, constructor, field initializer or
// static block may write it, in its parameters and arrows too. Refused
// code never starts: `ran` stays 0. Direct eval code goes by its caller.
globalThis.ran = 0;
function early(source) {
  var out;
  ran = 0;
  try { (0, eval)("ran = 1; " + source); out = "ok"; } catch (e) { out = e.constructor.name; }
  console.log(out + " " + ran + "  " + source);
}
// Refused.
early("super.x");
early("super['x']");
early("function f() { super.x }");
early("(function () { super.x })");
early("() => super.x");
early("(() => () => super[1])");
early("function* g() { super.x }");
early("async function f() { super.x }");
early("async function* f() { super.x }");
early("(async () => super.x)");
early("function f(a = super.x) {}");
early("(function (a = () => super.x) {})");
early("({ f: function () { super.x } })");
early("({ f: () => super.x })");
early("({ [super.x]: 1 })");
early("({ [super.x]() {} })");
early("({ a: super.x })");
early("class C { [super.x]() {} }");
early("class C { static [super.x] = 1 }");
early("class C extends (super.x) {}");
early("class C { m() { function g() { super.x } } }");
early("class C { m() { return function () { return () => super.x } } }");
early("class C { x = function () { super.y } }");
early("class C { static { function g() { super.x } } }");
early("({ m() { ({ f: function () { super.x } }) } })");
early("new super.x");
early("super.x = 1");
early("super.x()");
early("`${super.x}`");
early("function f() { `${super.x}` }");
// Allowed.
early("({ m() { super.x } })");
early("({ m(a = super.x) {} })");
early("({ get g() { return super.x }, set s(v) { super.x = v } })");
early("({ async m() { super.x }, *n() { super.x }, async *o() { super.x } })");
early("({ ['k']() { super.x }, get ['g']() { return super.x } })");
early("({ m() { () => super.x } })");
early("({ m() { `${super.x}` } })");
early("class C { m() { super.x } }");
early("class C { static m() { super.x } }");
early("class C { get g() { return super.x } set s(v) { super.x = v } }");
early("class C { constructor() { super.x } }");
early("class C { constructor(a = super.x) {} }");
early("class C { m() { () => () => super.x } }");
early("class C { x = super.y }");
early("class C { static x = super.y }");
early("class C { x = () => super.y }");
early("class C { static { super.x } }");
early("class C { static { () => super.x } }");
early("class C { #p = super.x; static #q() { return super.x } }");
early("class C { m() { new super.x } }");
early("class C { m() { class D { [super.x]() {} } } }");
early("class C { m() { class D extends (super.x) {} } }");
early("class C { m() { ({ [super.x]: 1, a: super.y }) } }");
early("class C { m() { function f() { ({ n() { super.x } }) } } }");
early("function f() { class C { m() { super.x } } }");
early("function f() { return { m() { return super.x } } }");
// Each answer ends with what it was given for.
early("class C { m() {} }; super.x");
early("class C { get g() { return 1 } }; super.x");
early("class C { x = 1 }; super.x");
early("class C { static {} }; super.x");
early("({ m() {} }); super.x");
early("({ get g() { return 1 } }); super.x");
early("({ ['k']() {} }); super.x");
early("class C { m() { function f() {} return super.x } }");
early("class C { m() { (function () {}); return super.x } }");
// The Function constructor's parameters and body are a function's.
["super.x", "() => super.x", "({ m() { super.x } })", "class C { x = super.y }"].forEach(function (s) {
  var out; try { new Function(s); out = "ok"; } catch (e) { out = e.constructor.name; } console.log(out + "  Function body " + s);
});
["a = super.x", "a = () => super.x"].forEach(function (s) {
  var out; try { new Function(s, ""); out = "ok"; } catch (e) { out = e.constructor.name; } console.log(out + "  Function parameter " + s);
});
// Direct eval.
function direct(label, f) {
  var out;
  ran = 0;
  try { out = String(f()); } catch (e) { out = e.constructor.name; }
  console.log(label + ": " + out + " " + ran);
}
var P = { x: "px" };
ran = 0;
try { console.log("script: " + eval("ran = 1; super.x") + " " + ran); } catch (e) { console.log("script: " + e.constructor.name + " " + ran); }
direct("function", function () { return eval("ran = 1; super.x"); });
direct("function, computed", function () { return eval("super[ran = 1]"); });
direct("arrow in a script", () => eval("ran = 1; super.x"));
direct("function in a method", function () { return ({ __proto__: P, m() { return (function () { return eval("ran = 1; super.x"); })(); } }).m(); });
direct("eval in eval in a function", function () { return eval("ran = 1; eval('ran = 2; super.x')"); });
direct("function written in a method's eval", function () { return ({ __proto__: P, m() { return eval("ran = 1; (function () { return super.x })"); } }).m(); });
direct("generator", function () { function* g() { yield eval("ran = 1; super.x"); } return g().next().value; });
direct("function's parameter", function () { function f(a = eval("ran = 1; super.x")) { return a; } return f(); });
direct("computed key in a function", function () { class C { [eval("ran = 1; super.x")]() {} } return 1; });
direct("indirect eval in a method", function () { return ({ __proto__: P, m() { return (0, eval)("ran = 1; super.x"); } }).m(); });
direct("Function in a method", function () { return ({ __proto__: P, m() { return new Function("ran = 1; return super.x")(); } }).m(); });
direct("method", function () { return ({ __proto__: P, m() { return eval("ran = 1; super.x"); } }).m(); });
direct("method's arrow", function () { return ({ __proto__: P, m() { return (() => eval("ran = 1; super.x"))(); } }).m(); });
direct("eval in eval in a method", function () { return ({ __proto__: P, m() { return eval("ran = 1; eval('ran = 2; super.x')"); } }).m(); });
direct("arrow written in a method's eval", function () { return ({ __proto__: P, m() { return eval("ran = 1; () => super.x")(); } }).m(); });
direct("method written in a method's eval", function () { return ({ __proto__: P, m() { return eval("ran = 1; ({ __proto__: { x: 'inner' }, n() { return super.x } })").n(); } }).m(); });
direct("getter", function () { return ({ __proto__: P, get g() { return eval("ran = 1; super.x"); } }).g; });
direct("class method", function () { class A { get x() { return "ax"; } } class B extends A { m() { return eval("ran = 1; super.x"); } } return new B().m(); });
direct("static method", function () { class A { static get x() { return "sx"; } } class B extends A { static m() { return eval("ran = 1; super.x"); } } return B.m(); });
direct("constructor", function () { class A { get x() { return "ax"; } } class B extends A { constructor() { super(); this.v = eval("ran = 1; super.x"); } } return new B().v; });
direct("field", function () { class A { get x() { return "ax"; } } class B extends A { v = eval("ran = 1; super.x"); } return new B().v; });
direct("static field", function () { class A { static get x() { return "sx"; } } class B extends A { static v = eval("ran = 1; super.x"); } return B.v; });
direct("static block", function () { var v; class A { static get x() { return "sx"; } } class B extends A { static { v = eval("ran = 1; super.x"); } } return v; });
direct("computed key in a method", function () { return ({ __proto__: P, m() { class C { static [eval("ran = 1; super.x")] = 1; } return Object.keys(C)[0]; } }).m(); });
direct("no super", function () { return eval("ran = 1; 7"); });
