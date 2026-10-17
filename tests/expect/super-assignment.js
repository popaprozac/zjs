// `super.x = v` is [[Set]] from the home object's prototype with `this`
// as the receiver: a setter there runs, a getter-only accessor refuses,
// and otherwise the receiver's own property is written or made -- in a
// class constructor too, whose home object is the prototype.
var log = [];
var target = {};
Object.defineProperty(target, "foo", { get() { return 1; }, configurable: true });
class A {
  constructor(returned) { if (returned) return target; this.own = 1; }
  set bar(v) { log.push("setter " + v + " on " + (this === target ? "target" : "instance")); }
  get onlyGet() { return 0; }
}
class B extends A {
  constructor(returned) {
    super(returned);
    super.bar = 5;
    try { super.foo = 14; } catch (e) { log.push("foo " + e.constructor.name); }
    super.baz = 3;
    super.own = 2;
  }
  write() {
    try { super.onlyGet = 1; } catch (e) { log.push("onlyGet " + e.constructor.name); }
    super.fresh = 9;
    return this;
  }
}
new B(true);
log.push(JSON.stringify(Object.getOwnPropertyDescriptor(target, "baz")));
const b = new B(false).write();
log.push(b.own, b.fresh, Object.keys(b).join(","));
var o = { __proto__: { set p(v) { log.push("proto setter " + v); } }, m() { super.p = 2; super.q = 3; return this.q; } };
log.push(o.m());
console.log(log.join("\n"));
