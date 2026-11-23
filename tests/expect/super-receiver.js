// `super.x` is [[Get]] from the home object's prototype with `this` as
// the receiver, whatever kind of object that prototype is. A class's is
// its parent class, a function: a getter found there, or anywhere past
// it, runs against the class the read is in, not against the parent.
function show(label, f) {
  var out;
  try { out = f(); } catch (e) { out = "threw " + e.constructor.name + ": " + e.message; }
  console.log(label + ": " + (typeof out == "string" ? out : JSON.stringify(out)));
}
class A {
  static get who() { return this.name; }
  static get self() { return this; }
  static set v(x) { this.got = x; }
  static k = 1;
  get who() { return this.tag; }
  static get f() { var self = this; return function () { return self.name + "/" + this.name; }; }
}
const sym = Symbol("s");
Object.defineProperty(A, sym, { get() { return this.name; }, configurable: true });
class B extends A {
  static m() { return super.who; }
  static c() { return super["who"]; }
  static y() { return super[sym]; }
  static arrow() { return (() => super.who)(); }
  static same() { return super.self === this; }
  static call() { return super.f(); }
  static set() { super.v = 5; return [Object.hasOwn(B, "got"), Object.hasOwn(A, "got"), B.got]; }
  static data() { return [super.k, super.name, super.length, super.prototype === A.prototype]; }
  static field = super.who;
  static fieldArrow = () => super.who;
  static block;
  static { this.block = super.who; }
  tag = "b";
  inst() { return super.who; }
}
class C extends B {
  static m2() { return super.who; }
  static viaB() { return super.m(); }
}
show("static method", () => B.m());
show("computed key", () => B.c());
show("symbol key", () => B.y());
show("arrow", () => B.arrow());
show("same object", () => B.same());
show("getter returns a function", () => B.call());
show("setter", () => B.set());
show("data and virtual", () => B.data());
show("static field", () => B.field);
show("static field arrow", () => B.fieldArrow());
show("static block", () => B.block);
show("instance getter", () => new B().inst());
show("two levels up", () => C.m2());
show("through a super call", () => C.viaB());
show("borrowed static method", () => B.m.call({ name: "other" }));

// The home object's prototype is a function, an array, a host function.
var o = { name: "o", m() { return super.who; }, n() { return super.self === this; } };
Object.setPrototypeOf(o, A);
show("object method, class as prototype", () => [o.m(), o.n()]);
var arr = [7];
Object.defineProperty(arr, "who", { get() { return this === p; } });
var p = { m() { return [super[0], super.length, super.who]; } };
Object.setPrototypeOf(p, arr);
show("array as prototype", () => p.m());
var h = { m() { return [super.name, super.length]; } };
Object.setPrototypeOf(h, Math.max);
show("host function as prototype", () => h.m());

// A getter past the parent class, on the parent's own prototype.
class D { static m() { return super.tagged; } }
Object.defineProperty(Function.prototype, "tagged", { get() { return this.name; }, configurable: true });
show("Function.prototype getter, base class", () => D.m());
class E extends D { static m2() { return super.tagged; } }
show("Function.prototype getter, derived", () => E.m2());
delete Function.prototype.tagged;
class F { static get who() { return "F:" + this.name; } }
class G extends A { static m() { return super.who; } }
Object.setPrototypeOf(G, F);
show("after reparenting", () => G.m());
var plain = { get who() { return "plain:" + this.name; } };
class H {}
Object.setPrototypeOf(H, plain);
class I extends H { static m() { return super.who; } }
show("class, then a plain object", () => I.m());

// The key is converted once, and what it or the getter throws comes out.
class K extends A {
  static badKey() { return super[{ toString() { throw new RangeError("key"); } }]; }
  static objKey() { var n = 0; var k = { toString() { n++; return "who"; } }; return [super[k], n]; }
  static intKey() { return super[0]; }
  static missing() { return super.nothing; }
  static throwing() { return super.boom; }
  static *gen() { yield super.who; }
  static async later() { return super.who; }
}
Object.defineProperty(A, "boom", { get() { throw new EvalError("getter of " + this.name); }, configurable: true });
A[0] = "zero";
show("key throws", () => K.badKey());
show("object key", () => K.objKey());
show("int key", () => K.intKey());
show("missing", () => K.missing());
show("getter throws", () => K.throwing());
show("generator", () => K.gen().next().value);
K.later().then(v => console.log("async: " + v));
