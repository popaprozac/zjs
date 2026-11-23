// Derived constructors: `this` is uninitialized until super() returns.
// Reads before it (typeof included, and through arrows created earlier)
// throw; arrows created before super() see the bound value after it;
// super() may run once; fields initialize right after it; returns follow
// the specified outcomes; base constructors are untouched. A class
// given no constructor has one made for it, and its field arrows and
// direct evals see `this` the same way.
var r = [];
function t(f) { try { r.push(String(f())); } catch (e) { r.push(e.constructor.name); } }
class B { constructor(x) { this.x = x === undefined ? "b" : x; } }
class Throwing { constructor() { throw new RangeError("boom"); } }
t(function () { class D extends B { constructor() { this.y = 1; super(); } } new D(); });
t(function () { class D extends B { constructor() { var t = typeof this; super(); return { t: t }; } } return new D().t; });
t(function () { class D extends B { constructor() { super(); return typeof this; } } new D(); return "ok"; });
t(function () { class D extends B { constructor() { var f = () => this; try { f(); } catch (e) { super(); return { seen: e.constructor.name + ":" + f().x }; } } } return new D().seen; });
t(function () { class D extends B { constructor() { var f = () => this.x; super("v"); return { got: f() }; } } return new D().got; });
t(function () { class D extends B { constructor() { super(1); super(2); } } new D(); });
t(function () { var calls = 0; class C extends B { constructor(v) { super(v); calls++; } } class D extends C { constructor() { try { super(1); super(2); } catch (e) { return { calls: calls, e: e.constructor.name }; } } } var o = new D(); return o.calls + "," + o.e; });
t(function () { class D extends Throwing { constructor() { try { super(); } catch (e) { return { e: e.message }; } } } return new D().e; });
t(function () { class D extends Throwing { constructor() { try { super(); } catch (e) {} this.z = 1; } } new D(); });
t(function () { var order = []; class D extends B { f = order.push("field"); constructor() { order.push("before"); super(); order.push("after"); } } new D(); return order.join(); });
t(function () { class D extends B { constructor() { return { custom: 1 }; } } return new D().custom; });
t(function () { class D extends B { constructor() { return 5; } } new D(); });
t(function () { class D extends B { constructor() { super(); return 5; } } new D(); });
t(function () { class D extends B { constructor() { super(); return undefined; } } return new D().x; });
t(function () { class D extends B { constructor() { super(); return null; } } new D(); });
t(function () { class D extends B { constructor() { return undefined; } } new D(); });
t(function () { class D extends B { constructor() { } } new D(); });
t(function () { class D extends B { } return new D("q").x; });
t(function () { class E { constructor() { return 5; } } return typeof new E(); });
t(function () { class E { constructor() { return undefined; } } return typeof new E(); });
t(function () { class E { constructor() { this.a = 1; } } return new E().a; });
t(function () { class D extends B { constructor() { (() => { this.q = 1; })(); super(); } } new D(); });
t(function () { class D extends B { constructor() { super(); (() => { this.q = 2; })(); return { q: this.q }; } } return new D().q; });
t(function () { class D extends B { constructor() { var s = "" + this; super(); } } new D(); });
t(function () { class D extends B { constructor() { super(); this.x; return this; } } return new D().x; });
t(function () { class D extends B { h = () => this.x; } return new D("later").h(); });
t(function () { class D extends B { f = (() => this.x)(); } return new D("at once").f; });
t(function () { class D extends B { a = 1; f = (() => this.a + 1)(); } return new D().f; });
t(function () { class D extends B { f = eval("this.x"); } return new D("eval").f; });
t(function () { class D extends B { f = (() => eval("this.x"))(); } return new D("arrow eval").f; });
t(function () { var D = class extends B { h = () => this; }; var d = new D(); return d.h() === d; });
t(function () { class D extends B { h = () => () => this.x; } return new D("nested").h()(); });
t(function () { class C extends B { c = () => this.x + "c"; } class D extends C { d = () => this.c() + "d"; } return new D("k").d(); });
t(function () { class D extends B { #p = () => this.x; get() { return this.#p(); } } return new D("private").get(); });
t(function () { class D extends B { ["k"] = () => this.x; } return new D("computed").k(); });
t(function () { class D extends B { h = () => this.x; } var a = new D("one"), b = new D("two"); return a.h() + b.h(); });
t(function () { class D extends Throwing { h = () => this; } new D(); });
t(function () { class D extends B { h = () => this.x; constructor() { super("explicit"); } } return new D().h(); });
console.log(r.join(","));
