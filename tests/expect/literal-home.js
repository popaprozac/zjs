// An object literal is the home object of its methods and accessors
// only, where `super` in them reads from. A function stored in one,
// by any spelling, keeps the home it had: a class's method still reads
// through its class, an arrow through the method it was written in, and
// a function with none still has none for direct eval code to use.
function show(label, f) {
  var out;
  try { out = String(f()); } catch (e) { out = "threw " + e.constructor.name; }
  console.log(label + ": " + out);
}
class A { m() { return "A.m"; } get g() { return "A.g"; } static s() { return "A.s"; } }
class B extends A { m() { return "B>" + super.m(); } get g() { return "B>" + super.g; } static s() { return "B>" + super.s(); } }
var P = { x: "px", m() { return "P.m"; } };
// A function stored in a literal keeps the home it had.
show("class method stored", function () { var b = new B(); var o = { m: B.prototype.m }; return b.m() + " " + o.m(); });
show("stored under a computed key", function () { var k = "m"; var o = { [k]: B.prototype.m }; return new B().m(); });
show("stored by shorthand", function () { var m = B.prototype.m; var o = { m }; return new B().m(); });
show("stored through a spread", function () { var o = { ...{ m: B.prototype.m } }; return new B().m(); });
show("getter stored", function () { var d = Object.getOwnPropertyDescriptor(B.prototype, "g"); var o = { g: d.get }; return new B().g; });
show("static method stored", function () { var o = { s: B.s }; return B.s(); });
show("object method stored in another", function () { var o = { __proto__: P, m() { return "o>" + super.m(); } }; var q = { m: o.m }; return o.m() + " " + q.m(); });
show("stored twice", function () { var o = { __proto__: P, m() { return super.x; } }; var q = { a: o.m, b: o.m }; return q.a() + q.b(); });
show("class stored", function () { var o = { C: class extends A { constructor() { super(); this.v = super.m(); } } }; return new o.C().v; });
show("class stored, static", function () { var o = { C: class extends A { static t() { return super.s(); } } }; return o.C.t(); });
show("arrow stored in a method", function () { class C extends A { n() { var o = { f: () => super.m() }; return o.f(); } } return new C().n(); });
show("arrow stored in an object method", function () { var q = { __proto__: P, m() { var o = { __proto__: null, f: () => super.m() }; return o.f(); } }; return q.m(); });
show("arrow stored, called later", function () { class C extends A { n() { return { f: () => super.m(), g: () => super.g }; } } var o = new C().n(); return o.f() + " " + o.g(); });
show("bound method stored", function () { var b = new B(); var o = { m: b.m.bind(b) }; return o.m() + " " + b.m(); });
// A function, however it is stored, has none.
show("function value, eval", function () { var o = { __proto__: P, m: function () { return eval("super.x"); } }; return o.m(); });
show("function value, computed key, eval", function () { var o = { __proto__: P, ["m"]: function () { return eval("super.x"); } }; return o.m(); });
show("arrow value in a function, eval", function () { var o = { __proto__: P, f: () => eval("super.x") }; return o.f(); });
show("generator function value, eval", function () { var o = { __proto__: P, g: function* () { yield eval("super.x"); } }; return o.g().next().value; });
// A method has the literal.
show("method", function () { return ({ __proto__: P, m() { return super.x; } }).m(); });
show("method call", function () { return ({ __proto__: P, m() { return "o>" + super.m(); } }).m(); });
show("computed key method", function () { return ({ __proto__: P, ["m"]() { return super.x; } }).m(); });
show("string key method", function () { return ({ __proto__: P, "m n"() { return super.x; } })["m n"](); });
show("number key method", function () { return ({ __proto__: P, 7() { return super.x; } })[7](); });
show("getter", function () { return ({ __proto__: P, get g() { return super.x; } }).g; });
show("computed getter", function () { return ({ __proto__: P, get ["g"]() { return super.x; } }).g; });
show("setter", function () { var seen; var o = { __proto__: { set x(v) { seen = "set " + v; } }, set s(v) { super.x = v; } }; o.s = 3; return seen; });
show("generator method", function () { return ({ __proto__: P, *m() { yield super.x; } }).m().next().value; });
show("parameter default", function () { return ({ __proto__: P, m(a = super.x) { return a; } }).m(); });
show("parameter default arrow", function () { return ({ __proto__: P, m(a = () => super.x) { return a(); } }).m(); });
show("destructured parameter default", function () { return ({ __proto__: P, m({ a = super.x } = {}) { return a; } }).m(); });
show("arrow in a method", function () { return ({ __proto__: P, m() { return (() => () => super.x)()(); } }).m(); });
show("eval in a method", function () { return ({ __proto__: P, m() { return eval("super.x"); } }).m(); });
show("eval in a method's arrow", function () { return ({ __proto__: P, m() { return (() => eval("super.x"))(); } }).m(); });
show("eval in a parameter default", function () { return ({ __proto__: P, m(a = eval("super.x")) { return a; } }).m(); });
show("eval in a getter", function () { return ({ __proto__: P, get g() { return eval("super.x"); } }).g; });
show("method after the prototype changes", function () { var o = { m() { return super.x; } }; var a = o.m(); Object.setPrototypeOf(o, P); return a + " " + o.m(); });
show("method called on another object", function () { var o = { __proto__: P, m() { return super.x; } }; return o.m.call({ x: "other" }); });
show("method in a method", function () { return ({ __proto__: P, m() { return ({ __proto__: { x: "inner" }, n() { return super.x; } }).n() + " " + super.x; } }).m(); });
show("two literals from one site", function () { function make(p) { return { __proto__: p, m() { return super.x; } }; } var a = make({ x: "one" }), b = make({ x: "two" }); return a.m() + b.m() + a.m(); });
show("literal in a loop", function () { var out = ""; for (var i = 0; i < 3; i++) { var o = { __proto__: { x: i }, m() { return super.x; }, n() { return 1; } }; out += o.m(); } return out; });
show("many properties", function () { var o = { __proto__: P, a: 1, b: function () { return 2; }, c() { return 3; }, d() { return super.x; }, get e() { return 5; }, f: () => 6 }; return [o.a, o.b(), o.c(), o.d(), o.e, o.f()].join(); });
show("method without super, names", function () { var o = { m() {}, get g() { return 1; }, f: function () {}, a: () => {} }; return [o.m.name, Object.getOwnPropertyDescriptor(o, "g").get.name, o.f.name, o.a.name].join(); });
// Settled after everything above.
({ __proto__: P, async m() { return super.x; } }).m().then(function (v) { console.log("async method: " + v); });
({ __proto__: P, f: async function () { return eval("super.x"); } }).f().then(function (v) { console.log("async function value, eval: " + v); }, function (e) { console.log("async function value, eval: threw " + e.constructor.name); });
