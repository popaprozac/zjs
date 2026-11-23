// A class's static block runs as a plain function on the class, once,
// while the class is defined: what it throws, the definition throws.
function show(label, f) { try { console.log(label, f()); } catch (e) { console.log(label, "threw", (e && e.name) || e); } }
show("throw", function () { class C { static { throw new RangeError("from the block"); } } return "defined"; });
show("throw from a call", function () { function fail() { throw new TypeError("deep"); } class C { static { fail(); } } return "defined"; });
show("missing method", function () { class C { static { this.missing(); } } return "defined"; });
show("class expression", function () { var seen = "unset"; try { seen = class { static { throw new SyntaxError("expr"); } }; } catch (e) { return e.name + "," + seen; } });
show("stops the rest", function () { var log = []; try { class C { static { log.push("a"); throw 1; } static { log.push("b"); } } } catch (e) { log.push("caught " + e); } return log.join(); });
show("order", function () { var log = []; class C { static { log.push("first"); } static x = log.push("field"); static { log.push("last"); } } log.push("after"); return log.join(); });
show("this and var", function () { class C { static { var kept = this; C.same = kept === C; C.arrow = (() => this)() === C; } } return [C.same, C.arrow, typeof kept].join(); });
show("try inside", function () { class C { static { try { throw new Error("in"); } catch (e) { C.caught = e.message; } finally { C.done = true; } } } return [C.caught, C.done].join(); });

// A static field's initializer that reads `this` runs as a function of
// the class too: `this` is the class in it and in its arrows, its key is
// the class definition's own expression, and what eval declares stays in it.
show("field this", function () { class C { static s = this; static n = this.name; } return [C.s === C, C.n].join(); });
show("field arrow", function () { class C { static t = () => this; static deep = () => () => this; } return [C.t() === C, C.deep()() === C].join(); });
show("field arrow in a literal", function () { class C { static o = { m: () => this }; static list = [() => this]; static now = (() => this)(); } return [C.o.m() === C, C.list[0]() === C, C.now === C].join(); });
show("field arrow, private", function () { class C { static #p = () => this; static get() { return C.#p(); } } return C.get() === C; });
show("field arrow, async", function () { class C { static t = async () => this; } C.t().then(function (v) { console.log("field arrow, async, later", v === C); }); return "pending"; });
show("field in a method", function () { var o = { f() { class C { static t = () => this; } return [(() => this)() === o, C.t() === C].join(); } }; return o.f(); });
show("field in a strict function", function () { "use strict"; return (function () { class C { static t = () => this; } return C.t() === C; }).call(undefined); });
show("field new.target", function () { var seen = "unset"; function Outer() { class C { static n = new.target; } seen = C.n; } new Outer(); return seen; });
show("field function has its own this", function () { class C { static f = function () { return this; }; static g = function () { return () => this; }; } var o = { f: C.f, g: C.g }; return [o.f() === o, o.g()() === o].join(); });
show("field key is the definition's", function () { var o = { k: "a", f() { return class { static [this.k] = 1; static [(() => this.k + "b")()] = this; }; } }; var C = o.f(); return [C.a, C.ab === C].join(); });
show("field key of a nested method", function () { class C { static tag = "m"; static inner = class { [this.tag]() { return 1; } }; } return typeof C.inner.prototype.m; });
show("field eval", function () { class C { static e = eval("var kept = 1; this"); static a = eval("() => this"); } return [C.e === C, C.a() === C, typeof kept].join(); });
show("field names", function () { class C { static t = () => this; static u = function () {}; static c = class {}; static k = () => 1; static "quoted key" = () => this; } return [C.t.name, C.u.name, C.c.name, C.k.name, C["quoted key"].name].join("|"); });
show("field order", function () { var log = []; class C { static a = log.push("a") && this; static { log.push("block"); } static b = (() => log.push("b"))(); static c = log.push("c"); } return log.join(); });
show("field throw", function () { var after = "unset"; try { class C { static a = (() => { throw new RangeError("x"); })(); static b = (after = "set"); } } catch (e) { return e.name + "," + after; } });
show("field define, not set", function () { var hit = false; class B { static set x(v) { hit = true; } } class C extends B { static x = this.name; } return [hit, Object.getOwnPropertyDescriptor(C, "x").value].join(); });
show("field sees the class's names", function () { var outer = 5; var D = class C { static #secret = 7; static me = this === C; static sum = (() => outer + C.#secret + this.#secret)(); }; return [D.me, D.sum].join(); });
show("field constants", function () { class C { static RED = 1; static NAME = "c"; static list = [1, 2]; static made = new Map(); static none; } return [C.RED, C.NAME, C.list.length, C.made instanceof Map, C.none, "none" in C].join(); });

// A method's computed key is an expression of the function the class is
// in: `this` there is that function's, and counts as its reading `this`.
show("method key this", function () { var o = { k: "m", f() { return class { [this.k]() { return 1; } static [this.k + "s"]() { return 2; } get [this.k + "g"]() { return 3; } }; } }; var C = o.f(); return [new C().m(), C.ms(), new C().mg].join(); });
show("method key this in an arrow", function () { var o = { k: "m", f() { return class { [(() => this.k)()]() { return 1; } }; } }; return typeof o.f().prototype.m; });

// Static fields and blocks run once the class is built: after every
// method and accessor is defined and every computed key evaluated, in
// the order they are written.
show("keys, then static elements", function () { var log = []; class C { static [(log.push("k1"), "a")] = log.push("v1"); [(log.push("k2"), "b")] = log.push("v2"); static { log.push("block"); } static [(log.push("k3"), "c")]() {} static d = log.push("v4"); } log.push("defined"); new C(); return log.join(); });
show("field calls a later method", function () { class C { static a = this.m(); static b = C.m(); static m() { return 1; } } return [C.a, C.b].join(); });
show("block calls a later method", function () { class C { static { this.a = this.m(); } static m() { return 1; } } return C.a; });
show("field reads a later accessor", function () { class C { static a = this.g; static get g() { return 2; } } return C.a; });
show("field reads a later field", function () { class C { static a = this.b; static b = 3; } return [C.a, C.b].join(); });
show("field makes an instance", function () { class C { static a = new this().m(); m() { return 4; } } return C.a; });
show("field calls a later private method", function () { class C { static a = C.#p(); static #p() { return 5; } } return C.a; });
show("a key's throw comes first", function () { var log = []; try { class C { static a = log.push("a"); static [(() => { throw new RangeError("k"); })()] = 1; } } catch (e) { log.push(e.name); } return log.join(); });
show("held keys", function () { class C { static ["k" + 1] = 1; static ["k" + 2] = (typeof gc == "function" && gc(), 2); m() {} static ["k" + 3] = this.k1 + this.k2; get g() { return 0; } } return Object.getOwnPropertyNames(C).filter(function (n) { return n[0] == "k"; }).join() + "," + C.k3; });
show("many held keys", function () { var src = "class C {"; for (var i = 0; i < 40; i++) src += " static ['k' + " + i + "] = " + i + "; m" + i + "() {}"; src += " static total = Object.getOwnPropertyNames(this).length; } [C.total, C.k0, C.k39].join()"; return eval(src); });

// `super` in a static field or block reads through the class: its home
// object is the class, so `super.k` is the parent class's `k`.
show("super in a field", function () { class B { static k = 7; } class C extends B { static s = super.k; } return C.s; });
show("super in a field's arrow", function () { class B { static k = 7; } class C extends B { static s = () => super.k; static t = () => () => super.k; } return [C.s(), C.t()()].join(); });
show("super call keeps this", function () { class B { static k = 7; static m() { return this.k; } } class C extends B { static k = 9; static s = super.m(); } return C.s; });
show("super in a block", function () { class B { static k = 7; static m() { return this.k; } } class C extends B { static k = 9; static { C.a = super.k; C.b = super.m(); C.c = (() => super.k)(); } } return [C.a, C.b, C.c].join(); });
show("super skips the class's own", function () { class B { static k = "parent"; } class C extends B { static k = "own"; static s = super.k; static { C.t = super.k; } } return [C.s, C.t].join(); });
show("super with no parent", function () { class C { static s = super.toString === Function.prototype.toString; static { C.t = typeof super.call; } } return [C.s, C.t].join(); });
show("super computed", function () { class B { static k = 7; } var name = "k"; class C extends B { static s = super[name]; static { C.t = super["k"]; } } return [C.s, C.t].join(); });
show("super write", function () { var hit = []; class B { static set p(v) { hit.push("B.p " + v + " " + this.name); } } class C extends B { static set p(v) { hit.push("C.p"); } static { super.p = 1; } static f = (() => { super.p = 2; })(); static q = (super.q = 3); } return hit.join() + "|" + C.q + "," + Object.prototype.hasOwnProperty.call(C, "q") + "," + Object.prototype.hasOwnProperty.call(B, "q"); });
show("super after reparenting", function () { class A { static k = "a"; } class B { static k = "b"; } class C extends A { static f = () => super.k; } var before = C.f(); Object.setPrototypeOf(C, B); return [before, C.f()].join(); });
show("super in a nested class's key", function () { class B { static k = "m"; } class C extends B { static inner = class { [super.k]() { return 1; } }; } return typeof C.inner.prototype.m; });
show("a method's super is its own", function () { class B { static k = "static"; k() { return "proto"; } } class C extends B { static { C.viaBlock = super.k; } m() { return super.k(); } static sm() { return super.k; } } return [C.viaBlock, new C().m(), C.sm()].join(); });
show("two classes, two homes", function () { class A { static k = "a"; } class B { static k = "b"; } function make(P) { return class extends P { static f = () => super.k; }; } var X = make(A), Y = make(B); return [X.f(), Y.f(), X.f()].join(); });
show("super outside a class", function () { try { return eval("(function () { return super.k; })()"); } catch (e) { return e.name; } });
