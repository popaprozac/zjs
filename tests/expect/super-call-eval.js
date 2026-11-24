// super() in direct eval code inside a derived constructor, as in an
// arrow function there (super-call.js): the code constructs the parent
// with the constructor's new.target, binds its `this` once, and defines
// the fields. The call's place decides: in a field's initializer, a
// method, or a function it is refused when the code is parsed. And
// new.target in eval code is its caller's.
var log = [];
function show(label, f) {
  var out;
  try { out = f(); } catch (e) { out = "threw " + e.constructor.name; }
  console.log(label + ": " + out);
}
{
  class A {
    constructor(a, b) { log.push("A"); this.a = a; this.b = b; this.nt = new.target; }
    m() { return "A.m"; }
  }
  show("eval", () => {
    class B extends A { constructor() { eval("super(1, 2)"); this.c = 3; } }
    const b = new B();
    return [b instanceof B, b.a, b.b, b.c, b.nt === B].join();
  });
  show("eval, this afterwards in the eval", () => {
    class B extends A { constructor() { eval("super(1); this.x = this.a + 1"); } }
    return new B().x;
  });
  show("eval in an arrow", () => {
    class B extends A { constructor() { (() => eval("super(5)"))(); } }
    return new B().a;
  });
  show("arrow in eval", () => {
    class B extends A { constructor() { eval("(() => super(6))()"); } }
    return new B().a;
  });
  show("eval in eval", () => {
    class B extends A { constructor() { eval("eval('super(7)')"); } }
    return new B().a;
  });
  show("eval twice", () => {
    log = [];
    class B extends A { constructor() { eval("super()"); try { eval("super()"); } catch (e) { log.push(e.constructor.name); } } }
    new B();
    return log.join();
  });
  show("eval, fields", () => {
    class B extends A { x = this.a + 1; constructor() { eval("super(1)"); } }
    return new B().x;
  });
}

{
  var y = "outer";
  class A {
    constructor(a) { log.push("A"); this.a = a; this.nt = new.target; }
    get tag() { return "tag of " + this.a; }
  }
  show("eval, new.target is the subclass", () => {
    class B extends A { constructor() { eval("super()"); } }
    class C extends B {}
    const c = new C();
    return [c.nt === C, Object.getPrototypeOf(c) === C.prototype].join();
  });
  show("eval, value of super()", () => {
    class B extends A { constructor() { this.same = eval("super()") === this; } }
    return new B().same;
  });
  show("eval, spread arguments", () => {
    class B extends A { constructor(...args) { eval("super(...args)"); } }
    return new B(4).a;
  });
  show("eval reads the constructor's locals", () => {
    class B extends A { constructor(v) { const w = v + 1; eval("super(w)"); } }
    return new B(1).a;
  });
  show("eval in a parameter default", () => {
    class B extends A { constructor(v = eval("super(5)")) { this.same = v === this; } }
    return new B().same;
  });
  show("eval in a block with a let", () => {
    class B extends A { constructor() { { let z = 6; eval("super(z)"); } this.b = this.a + 1; } }
    return new B().b;
  });
  show("eval, super getter afterwards in the constructor", () => {
    class B extends A { constructor() { eval("super(1)"); this.r = super.tag; } }
    return new B().r;
  });
  show("eval, super getter afterwards in the eval", () => {
    class B extends A { constructor() { this.r = eval("super(2); super.tag"); } }
    return new B().r;
  });
  show("eval makes an arrow that is called later", () => {
    class B extends A { constructor() { const f = eval("() => super(7)"); f(); } }
    return new B().a;
  });
  show("eval's arrow called after the constructor returned an object", () => {
    var f;
    log = [];
    class B extends A { constructor() { f = eval("() => super()"); return { made: 1 }; } }
    const o = new B();
    const made = f();
    try { f(); } catch (e) { log.push(e.constructor.name); }
    return [o.made, made instanceof B, log.join()].join();
  });
  show("eval then the constructor's own super()", () => {
    log = [];
    class B extends A { constructor() { eval("super()"); try { super(); } catch (e) { log.push(e.constructor.name); } } }
    new B();
    return log.join();
  });
  show("the constructor's own super() then eval", () => {
    log = [];
    class B extends A { constructor() { super(); try { eval("super()"); } catch (e) { log.push(e.constructor.name); } } }
    new B();
    return log.join();
  });
  show("eval, fields and their scope", () => {
    class B extends A { x = y; f = () => y; t = new.target; constructor(y) { eval("super()"); } }
    const b = new B("param");
    return [b.x, b.f(), b.t].join();
  });
  show("eval, private field and method", () => {
    class B extends A { #p = 3; #m() { return this.#p + 1; } constructor() { eval("super()"); this.r = this.#m(); } }
    return new B().r;
  });
  show("an eval that never calls super()", () => {
    class B extends A { constructor() { eval("1 + 1"); } }
    return new B();
  });
  show("an eval that never calls super(), then the constructor's own", () => {
    class B extends A { x = 1; constructor() { const v = eval("1 + 1"); super(v); } }
    const b = new B();
    return [b.a, b.x].join();
  });
  show("eval of a nested class with a derived constructor", () => {
    class B extends A { constructor() { super(1); this.k = eval("(class extends A { constructor() { super(2); } })"); } }
    return new (new B().k)().a;
  });
  show("many constructions through eval", () => {
    class B extends A { x = 1; constructor(i) { eval("super(i)"); } }
    var sum = 0;
    for (var i = 0; i < 300; i++) { const b = new B(i); sum += b.a + b.x; }
    return sum;
  });

  // Refused
  show("eval in an arrow in a field initializer", () => {
    class B extends A { x = (() => eval("super()"))(); }
    return new B();
  });
  show("eval in eval in a field initializer", () => {
    class B extends A { x = eval("eval('super()')"); }
    return new B();
  });
  show("eval in a field initializer of a class with a written constructor", () => {
    class B extends A { x = eval("super()"); constructor() { super(); } }
    return new B();
  });
  show("eval in a field initializer, the constructor's super() in an arrow", () => {
    class B extends A { x = eval("super()"); constructor() { (() => super())(); } }
    return new B();
  });
  show("eval in a static method", () => {
    class B extends A { static m() { return eval("super()"); } }
    return B.m();
  });
  show("eval in a getter", () => {
    class B extends A { get g() { return eval("super()"); } }
    return new B().g;
  });
  show("eval in an object's method in a derived constructor", () => {
    class B extends A { constructor() { super(); ({ m() { eval("super()"); } }).m(); } }
    return new B();
  });
  show("eval of a function that calls super()", () => {
    class B extends A { constructor() { super(); eval("(function () { super(); })"); } }
    return new B();
  });
  show("eval at the top of a function", () => {
    return (function () { return eval("super()"); })();
  });

  // new.target in eval code
  show("eval new.target in a function called with new", () => {
    function F() { this.t = eval("new.target") === F; }
    return new F().t;
  });
  show("eval new.target in a function called without new", () => {
    function F() { return eval("new.target"); }
    return F();
  });
  show("eval new.target in an arrow in a function", () => {
    function F() { this.t = (() => eval("new.target"))() === F; }
    return new F().t;
  });
  show("arrow in eval reads new.target", () => {
    function F() { this.t = eval("(() => new.target)")() === F; }
    return new F().t;
  });
  show("eval in eval reads new.target", () => {
    function F() { this.t = eval("eval('new.target')") === F; }
    return new F().t;
  });
  show("eval new.target in a derived constructor", () => {
    class B extends A { constructor() { super(); this.t = eval("new.target") === B; } }
    return new B().t;
  });
  show("eval new.target in a method", () => {
    class B { m() { return eval("new.target"); } }
    return new B().m();
  });
  show("eval new.target in a field initializer", () => {
    class B { x = eval("new.target"); f = eval("() => new.target"); }
    const b = new B();
    return [b.x, b.f()].join();
  });
  show("eval new.target in a field initializer of a derived class", () => {
    class B extends A { x = eval("new.target"); constructor() { super(); this.t = eval("new.target") === B; } }
    const b = new B();
    return [b.x, b.t].join();
  });
}
