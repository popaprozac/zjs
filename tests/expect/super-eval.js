// Direct eval code in a method reads through `super` as the method
// does: it runs with the caller's home object, and so do the arrows and
// the direct evals inside it. Where the caller has none (a function, a
// script, indirect eval) the read is refused.
function show(label, f) {
  var out;
  try { out = f(); } catch (e) { out = "threw " + e.constructor.name; }
  console.log(label + ": " + (typeof out == "string" ? out : JSON.stringify(out)));
}
class A {
  m() { return "A.m"; }
  get g() { return "g of " + this.tag; }
  set w(v) { this.got = "set " + v; }
  static s() { return "A.s"; }
  static get who() { return this.name; }
}
show("method", () => { class B extends A { m() { return eval("super.m()"); } } return new B().m(); });
show("getter", () => { class B extends A { tag = "b"; v() { return eval("super.g"); } } return new B().v(); });
show("computed", () => { class B extends A { m() { return eval("super['m']()"); } } return new B().m(); });
show("arrow around eval", () => { class B extends A { m() { return (() => eval("super.m()"))(); } } return new B().m(); });
show("arrow inside eval", () => { class B extends A { m() { return eval("(() => super.m())")(); } } return new B().m(); });
show("arrow kept from eval", () => { class B extends A { m() { return eval("() => super.m()"); } } var kept = new B().m(); return kept(); });
show("nested eval", () => { class B extends A { m() { return eval("eval('super.m()')"); } } return new B().m(); });
show("write runs the setter", () => { class B extends A { m() { eval("super.w = 5"); return [this.got, Object.hasOwn(this, "w")]; } } return new B().m(); });
show("static method", () => { class B extends A { static s() { return eval("super.s()"); } } return B.s(); });
show("static getter", () => { class B extends A { static s() { return eval("super.who"); } } return B.s(); });
show("static field", () => { class B extends A { static f = eval("super.s()"); } return B.f; });
show("static field arrow", () => { class B extends A { static f = () => eval("super.s()"); } return B.f(); });
show("static block", () => { class B extends A { static b; static { this.b = eval("super.s()"); } } return B.b; });
show("instance field", () => { class B extends A { f = eval("super.m()"); } return new B().f; });
show("constructor", () => { class B extends A { constructor() { super(); this.c = eval("super.m()"); } } return new B().c; });
show("base constructor", () => { class B { constructor() { this.c = eval("typeof super.toString"); } } return new B().c; });
show("object method", () => { var o = { __proto__: { m() { return "proto.m"; } }, m() { return eval("super.m()"); } }; return o.m(); });
show("object getter", () => { var o = { __proto__: { x: 7 }, get g() { return eval("super.x"); } }; return o.g; });
show("generator method", () => { class B extends A { *m() { yield eval("super.m()"); } } return new B().m().next().value; });
show("parameter default", () => { class B extends A { m(x = eval("super.m()")) { return x; } } return new B().m(); });
show("after reparenting", () => { var o = { m() { return eval("super.m()"); } }; Object.setPrototypeOf(o, { m() { return "first"; } }); var a = o.m(); Object.setPrototypeOf(o, { m() { return "second"; } }); return [a, o.m()]; });
show("two methods, two homes", () => { var p = { n() { return "p"; } }, q = { n() { return "q"; } }; var a = { __proto__: p, m() { return eval("super.n()"); } }, b = { __proto__: q, m() { return eval("super.n()"); } }; return [a.m(), b.m()]; });
show("eval without super", () => { class B extends A { m() { return eval("1 + 1"); } } return new B().m(); });
console.log("-- refused");
show("indirect eval", () => { class B extends A { m() { return (0, eval)("super.m()"); } } return new B().m(); });
show("function around eval", () => { class B extends A { m() { return function () { return eval("super.m()"); }.call(this); } } return new B().m(); });
show("top level", () => eval("super.m()"));
show("plain function", () => (function () { return eval("super.m()"); })());
show("arrow at top level", () => (() => eval("super.m()"))());
class L extends A { async m() { return eval("super.m()"); } }
new L().m().then(v => console.log("async method: " + v));
