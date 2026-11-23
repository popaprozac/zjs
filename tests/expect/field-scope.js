// An instance field's initializer runs in the class body's scope, not the constructor's.
function show(label, f) {
  var out;
  try { out = f(); } catch (e) { out = "threw " + e.constructor.name; }
  console.log(label + ": " + out);
}
function early(label, source) {
  var out = "accepted";
  try { (0, eval)(source); } catch (e) { out = e.constructor.name; }
  console.log(label + ": " + out);
}
var y = "outer";
class A { constructor(v) { this.v = v; } }

show("parameter of the same name", () => {
  class B { x = y; constructor(y) {} }
  return new B("param").x;
});
show("var of the same name", () => {
  class B { x = y; constructor() { var y = "inner"; } }
  return new B().x;
});
show("let of the same name", () => {
  class B { x = y; constructor() { let y = "inner"; } }
  return new B().x;
});
show("function of the same name", () => {
  class B { x = typeof y; constructor() { function y() {} } }
  return new B().x;
});
show("derived, parameter", () => {
  class B extends A { x = y; constructor(y) { super(y); } }
  const b = new B("param");
  return [b.x, b.v].join();
});
show("derived, let after super()", () => {
  class B extends A { x = y; constructor() { super(); let y = "inner"; } }
  return new B().x;
});
show("derived, let before super()", () => {
  class B extends A { x = y; constructor() { let y = "inner"; super(); } }
  return new B().x;
});
show("derived, super() in a block with a let", () => {
  class B extends A { x = y; constructor() { { let y = "inner"; super(); } } }
  return new B().x;
});
show("derived, super() in a catch with a parameter", () => {
  class B extends A { x = y; constructor() { try { throw "caught"; } catch (y) { super(); } } }
  return new B().x;
});
show("local of the enclosing function", () => {
  let y = "enclosing";
  class B { x = y; constructor(y) {} }
  return new B("param").x;
});
show("parameter of the enclosing function", () => {
  return ((y) => { class B { x = y; constructor(y) {} } return new B("param").x; })("enclosing");
});
show("enclosing local, read and written", () => {
  let n = 0;
  class B { x = ++n; constructor(n) {} }
  new B(10); new B(20);
  return n;
});
show("arrow in the initializer", () => {
  class B { f = () => y; constructor(y) {} }
  return new B("param").f();
});
show("arrow in the initializer, enclosing local", () => {
  let y = "enclosing";
  class B { f = () => y; constructor(y) {} }
  return new B("param").f();
});
show("function in the initializer", () => {
  class B { f = function () { return y; }; constructor(y) {} }
  return new B("param").f();
});
show("class in the initializer", () => {
  class B { k = class K { static n = y; static me = K; }; constructor(y, K) {} }
  const b = new B("param", "pk");
  return [b.k.n, b.k.me === b.k].join();
});
show("class with a private name in the initializer", () => {
  class B { k = class { #p = y; get p() { return this.#p; } }; constructor(y) {} }
  return new (new B("param").k)().p;
});
show("later field reads an earlier one", () => {
  class B { a = y; b = this.a + "!"; constructor(y, a) {} }
  return new B("param", "pa").b;
});
show("the class's own name", () => {
  class B { x = B.tag; static tag = "tag"; constructor(B) {} }
  return new B("param").x;
});
show("private field", () => {
  class B { #p = y; get p() { return this.#p; } constructor(y) {} }
  return new B("param").p;
});
show("computed key", () => {
  const k = "key";
  class B { [k] = y; constructor(y, k) {} }
  return new B("param", "pk").key;
});
show("the constructor still sees its own", () => {
  class B { x = y; constructor(y) { this.mine = y; } }
  const b = new B("param");
  return [b.x, b.mine].join();
});
show("the constructor's arrow still sees its own", () => {
  class B { x = y; constructor(y) { this.f = () => y; } }
  const b = new B("param");
  return [b.x, b.f()].join();
});
show("typeof an undeclared name the constructor declares", () => {
  class B { x = typeof onlyInConstructor; constructor(onlyInConstructor) {} }
  return new B(1).x;
});
show("undeclared name the constructor declares", () => {
  class B { x = onlyInConstructor; constructor(onlyInConstructor) {} }
  return new B(1).x;
});
show("assignment in the initializer", () => {
  let y = "enclosing";
  class B { x = (y = "set"); constructor(y) { this.mine = y; } }
  const b = new B("param");
  return [y, b.mine].join();
});
show("eval in the initializer", () => {
  class B { x = eval("y"); constructor(y) {} }
  return new B("param").x;
});
show("eval in the initializer, enclosing local", () => {
  let y = "enclosing";
  class B { x = eval("y"); constructor(y) {} }
  return new B("param").x;
});
show("eval var in the initializer does not reach the constructor", () => {
  class B { x = eval("var q = 1; q"); constructor() { this.seen = typeof q; } }
  const b = new B();
  return [b.x, b.seen].join();
});
show("new.target", () => {
  class B { x = new.target; }
  return new B().x;
});
show("new.target, written constructor", () => {
  class B { x = new.target; constructor() {} }
  return new B().x;
});
show("new.target in an arrow", () => {
  class B { f = () => new.target; constructor() { this.t = new.target === B; } }
  const b = new B();
  return [b.f(), b.t].join();
});
show("new.target, derived", () => {
  class B extends A { x = new.target; f = () => new.target; }
  const b = new B();
  return [b.x, b.f()].join();
});
show("new.target in eval in the initializer", () => {
  class B { x = eval("new.target"); }
  return new B().x;
});
show("arguments in a function in the initializer", () => {
  class B { x = (function () { return arguments.length; })(1, 2, 3); constructor(a) {} }
  return new B(1).x;
});
show("eval in an arrow in the initializer", () => {
  class B { x = (() => eval("y"))(); constructor(y) {} }
  return new B("param").x;
});
show("class with a field in the initializer", () => {
  class B { k = class { z = y; constructor(y) {} }; constructor(y) {} }
  return new (new B("param").k)("inner").z;
});
show("class in the constructor, its field reads the parameter", () => {
  class B { constructor(y) { this.k = class { z = y; }; } }
  return new (new B("param").k)().z;
});
show("derived, two super() calls", () => {
  class B extends A { x = y; constructor(c, y) { if (c) super("then"); else super("else"); } }
  const t = new B(true, "param"), e = new B(false, "param");
  return [t.x, t.v, e.x, e.v].join();
});
show("with object around the class", () => {
  function make(o) { with (o) { return class { x = y; constructor(y) {} }; } }
  return new (make({ y: "with" }))("param").x;
});
show("constructor's local function of the same name is not called", () => {
  function pick() { return "outer pick"; }
  class B { x = pick(); constructor() { function pick() { return "inner pick"; } } }
  return new B().x;
});
show("new.target in an arrow in an arrow", () => {
  class B { f = () => () => new.target; constructor() {} }
  return new B().f()();
});
show("new.target in a function in the initializer", () => {
  class B { x = new (function () { this.t = new.target !== undefined; })().t; }
  return new B().x;
});
show("new.target in an arrow in a function in the initializer", () => {
  class B { x = new (function () { this.t = (() => new.target)() !== undefined; })().t; }
  return new B().x;
});
show("new.target in the constructor's own arrow", () => {
  class B { x = 1; constructor() { this.t = (() => new.target)() === B; } }
  return new B().t;
});
show("static field next to a parameter of the same name", () => {
  class B { static s = y; constructor(y) {} }
  return B.s;
});

early("arguments", "(class { x = arguments; })");
early("arguments in an arrow", "(class { x = () => arguments; })");
early("arguments in a function", "(class { x = function () { return arguments; }; })");
early("arguments, static", "(class { static x = arguments; })");
early("arguments in a computed key", "(function () { return class { [arguments.length] = 1; }; })");
