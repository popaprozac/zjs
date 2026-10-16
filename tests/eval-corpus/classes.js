var log = [];
class Point {
  constructor(x, y) { this.x = x; this.y = y; }
  sum() { return this.x + this.y; }
  get len() { return this.x * this.x + this.y * this.y; }
  set len(v) { this.x = v; }
  static origin() { return new Point(0, 0); }
  static count = 7;
  toString() { return "P(" + this.x + "," + this.y + ")"; }
}
var p = new Point(3, 4);
log.push(p.sum(), p.len, String(p), Point.origin().sum(), Point.count, typeof Point, Point.name, Point.length, p instanceof Point, Object.getPrototypeOf(p) === Point.prototype, p.constructor === Point);
log.push(Object.keys(Point.prototype).length, Object.getOwnPropertyNames(Point.prototype).sort().join(), Object.getOwnPropertyDescriptor(Point.prototype, "sum").enumerable, Object.getOwnPropertyDescriptor(Point, "prototype").writable, p.sum.name, Object.getOwnPropertyDescriptor(Point.prototype, "len").get.name);
p.len = 9;
log.push(p.x, p.hasOwnProperty("x"), Point.prototype.hasOwnProperty("sum"));
class Point3 extends Point {
  constructor(x, y, z) { super(x, y); this.z = z; }
  sum() { return super.sum() + this.z; }
  static origin() { return new Point3(0, 0, 0); }
  get len() { return super.len + this.z; }
}
var q = new Point3(1, 2, 3);
log.push(q.sum(), q instanceof Point, q instanceof Point3, Point3.origin().sum(), Object.getPrototypeOf(Point3) === Point, Object.getPrototypeOf(Point3.prototype) === Point.prototype, String(q), q.constructor === Point3);
class Base { constructor() { this.kind = "base"; } who() { return this.kind; } }
class Derived extends Base { who() { return "derived:" + super.who(); } }
var d = new Derived();
log.push(d.who(), d.kind, new (class extends Derived {})().who());
class Fields {
  a = 1;
  b = this.a + 1;
  ["c" + "d"] = 3;
  static s = "S";
  #secret = 42;
  #hidden() { return this.#secret * 2; }
  reveal() { return this.#hidden(); }
  static has(o) { return #secret in o; }
  set secret(v) { this.#secret = v; }
}
var f = new Fields();
log.push(f.a, f.b, f.cd, Fields.s, f.reveal(), Fields.has(f), Fields.has({}), Object.keys(f).join(), Object.getOwnPropertyNames(f).length, Object.getOwnPropertySymbols(f).length);
f.secret = 5;
log.push(f.reveal(), JSON.stringify(f));
var Anon = class {};
var Named = class Inner { self() { return Inner; } };
log.push(Anon.name, Named.name, typeof Inner);
class Counter { static n = 0; constructor() { Counter.n++; } }
new Counter(); new Counter();
log.push(Counter.n);
function checkNewTarget() { return new.target === undefined; }
class NT { constructor() { this.nt = new.target; } }
class NT2 extends NT {}
log.push(checkNewTarget(), new NT().nt === NT, new NT2().nt === NT2);
var errors = [];
try { Point(); } catch (e) { errors.push(e.name); }
try { new (class extends Base { constructor() { } })(); } catch (e) { errors.push(e.name); }
try { class X extends 3 {} } catch (e) { errors.push(e.name); }
try { new p.sum(); } catch (e) { errors.push(e.name); }
try { new (class extends Base { constructor() { super(); super(); } })(); } catch (e) { errors.push(e.name); }
log.push(errors.join());
class Nul extends null { constructor() { return Object.create(Nul.prototype); } }
log.push(Object.getPrototypeOf(Nul.prototype), new Nul() instanceof Nul);
class Gen { *items() { yield 1; yield 2; } static *statics() { yield "s"; } }
log.push([...new Gen().items()].join(), [...Gen.statics()].join());
class Sym { [Symbol.iterator]() { return [7, 8][Symbol.iterator](); } get [Symbol.toStringTag]() { return "Sym"; } }
log.push([...new Sym()].join(), Object.prototype.toString.call(new Sym()));
class Acc { static get v() { return 1; } static set v(x) { Acc.w = x; } }
Acc.v = 5;
log.push(Acc.v, Acc.w);
log.join("|");
