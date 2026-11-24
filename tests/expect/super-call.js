// super() in an arrow function inside a derived constructor: the arrow
// constructs the parent with the constructor's new.target, binds the
// constructor's `this` (once), and defines the class's fields, whether
// the constructor is still running or has returned. Elsewhere super()
// is refused when the source is parsed, in direct eval code too.
var log = [];
function show(label, f) {
  var out;
  try { out = f(); } catch (e) { out = "threw " + e.constructor.name; }
  console.log(label + ": " + out);
}
class A {
  constructor(a, b) { log.push("A"); this.a = a; this.b = b; this.nt = new.target; }
  m() { return "A.m"; }
}

// K: arrows
show("arrow, immediately called", () => {
  class B extends A { constructor() { (() => super(1, 2))(); this.c = 3; } }
  const b = new B();
  return [b instanceof B, b.a, b.b, b.c, b.nt === B].join();
});
show("arrow, value of super()", () => {
  class B extends A { constructor() { const r = (() => super())(); this.same = r === this; } }
  return new B().same;
});
show("arrow, called later in the constructor", () => {
  class B extends A { constructor() { const f = () => super(7); f(); } }
  return new B().a;
});
show("arrow in an arrow", () => {
  class B extends A { constructor() { (() => (() => super(8))())(); } }
  return new B().a;
});
show("arrow, spread arguments", () => {
  class B extends A { constructor(...args) { (() => super(...args))(); } }
  const b = new B(4, 5);
  return [b.a, b.b].join();
});
show("arrow, arguments evaluated in the arrow", () => {
  class B extends A { constructor(x) { ((y) => super(x, y))(6); } }
  const b = new B(5);
  return [b.a, b.b].join();
});
show("this before the arrow runs", () => {
  class B extends A { constructor() { const f = () => super(); this.x = 1; f(); } }
  return new B().x;
});
show("this in the constructor after the arrow", () => {
  class B extends A { constructor() { (() => super(1))(); this.x = this.a + 1; return; } }
  return new B().x;
});
show("this in the arrow after super()", () => {
  class B extends A { constructor() { (() => { super(1); this.x = this.a + 1; })(); } }
  return new B().x;
});
show("this in another arrow after the arrow", () => {
  class B extends A { constructor() { (() => super(2))(); (() => { this.x = this.a + 1; })(); } }
  return new B().x;
});
show("never called", () => {
  class B extends A { constructor() { const f = () => super(); } }
  return new B();
});
show("called twice", () => {
  log = [];
  class B extends A { constructor() { const f = () => super(); f(); try { f(); } catch (e) { log.push(e.constructor.name); } } }
  new B();
  return log.join();
});
show("constructor then arrow", () => {
  log = [];
  class B extends A { constructor() { super(); try { (() => super())(); } catch (e) { log.push(e.constructor.name); } } }
  new B();
  return log.join();
});
show("arrow then constructor", () => {
  log = [];
  class B extends A { constructor() { (() => super())(); try { super(); } catch (e) { log.push(e.constructor.name); } } }
  new B();
  return log.join();
});
show("new.target is the subclass", () => {
  class B extends A { constructor() { (() => super())(); } }
  class C extends B {}
  const c = new C();
  return [c.nt === C, Object.getPrototypeOf(c) === C.prototype].join();
});
show("parent read when super() runs", () => {
  class B extends A { constructor() { (() => super())(); } }
  class Z { constructor() { this.z = 1; } }
  Object.setPrototypeOf(B, Z);
  return new B().z;
});
show("parent not a constructor", () => {
  class B extends A { constructor() { (() => super())(); } }
  Object.setPrototypeOf(B, null);
  return new B();
});
show("fields after the arrow's super()", () => {
  class B extends A { x = this.a + 1; #p = 5; constructor() { (() => super(1))(); this.y = this.#p; } }
  const b = new B();
  return [b.x, b.y].join();
});
show("fields see the arrow's super() once", () => {
  var n = 0;
  class B extends A { x = ++n; constructor() { const f = () => super(); f(); try { f(); } catch (e) {} } }
  new B();
  return n;
});
show("private method after the arrow's super()", () => {
  class B extends A { #m() { return "pm"; } constructor() { (() => super())(); this.r = this.#m(); } }
  return new B().r;
});
show("arrow called through a builtin", () => {
  class B extends A { constructor() { [9].forEach((v) => super(v)); } }
  return new B().a;
});
show("arrow called from another function", () => {
  function call(f) { return f(); }
  class B extends A { constructor() { call(() => super(3)); } }
  return new B().a;
});
show("arrow in a parameter default", () => {
  class B extends A { constructor(f = () => super(4)) { f(); } }
  return new B().a;
});
show("returned object, arrow called afterwards", () => {
  var f;
  log = [];
  class B extends A { constructor() { f = () => super(); return { made: 1 }; } }
  const o = new B();
  const made = f();
  try { f(); } catch (e) { log.push(e.constructor.name); }
  return [o.made, made instanceof B, log.join()].join();
});
show("arrow called after the constructor threw", () => {
  var f;
  class B extends A { constructor() { f = () => super(); } }
  try { new B(); } catch (e) {}
  return f() instanceof B;
});
show("super() throws inside the arrow", () => {
  class T { constructor() { throw new RangeError("t"); } }
  class B extends T { constructor() { (() => super())(); } }
  return new B();
});
show("super.m() in the arrow after super()", () => {
  class B extends A { constructor() { (() => { super(); this.r = super.m(); })(); } }
  return new B().r;
});
show("try, finally with the arrow", () => {
  class B extends A { constructor() { try { return; } finally { (() => super(1))(); } } }
  return new B().a;
});
show("return override then arrow in finally", () => {
  class B extends A { constructor() { var f = () => super(1); try { return {}; } finally { f(); } } }
  return new B().a;
});
show("async arrow", () => {
  class B extends A { constructor() { (async () => super(1))(); } }
  return new B().a;
});
show("derived constructor inside the arrow's class", () => {
  class B extends A { constructor() { (() => super(1))(); this.inner = new (class extends A { constructor() { (() => super(2))(); } })().a; } }
  const b = new B();
  return [b.a, b.inner].join();
});

// Direct eval code may not call super() (yet, in a derived constructor)
show("indirect eval", () => {
  class B extends A { constructor() { (0, eval)("super()"); } }
  return new B();
});
show("eval in a base constructor", () => {
  class B { constructor() { eval("super()"); } }
  return new B();
});
show("eval in a method", () => {
  class B extends A { m() { eval("super()"); } }
  return new B().m();
});
show("eval in a function in a derived constructor", () => {
  class B extends A { constructor() { super(); (function () { eval("super()"); })(); } }
  return new B();
});
show("eval in a field initializer", () => {
  class B extends A { x = eval("super()"); }
  return new B();
});
show("eval in a static block of a derived class", () => {
  class B extends A { static { eval("super()"); } }
  return 1;
});

// Early errors (each source compiled on its own)
function early(label, source) {
  var out = "accepted";
  try { (0, eval)(source); } catch (e) { out = e.constructor.name; }
  console.log(label + ": " + out);
}
early("arrow in a derived constructor", "(class extends Object { constructor() { () => super(); } })");
early("arrow in a base constructor", "(class { constructor() { () => super(); } })");
early("arrow in a method", "(class extends Object { m() { () => super(); } })");
early("arrow in a field initializer", "(class extends Object { x = () => super(); })");
early("arrow in a static block", "(class extends Object { static { () => super(); } })");
early("function in a derived constructor", "(class extends Object { constructor() { function f() { super(); } } })");
early("function expression in a derived constructor", "(class extends Object { constructor() { (function () { super(); }); } })");
early("method of an object in a derived constructor", "(class extends Object { constructor() { ({ m() { super(); } }); } })");
early("class method in a derived constructor", "(class extends Object { constructor() { (class { m() { super(); } }); } })");
early("base class constructor in a derived constructor", "(class extends Object { constructor() { (class { constructor() { super(); } }); } })");
early("parameter default of a derived constructor", "(class extends Object { constructor(a = super()) {} })");
early("arrow at the top level", "() => super()");
early("getter of a derived class", "(class extends Object { get x() { super(); } })");
early("static method of a derived class", "(class extends Object { static m() { super(); } })");

// Receivers of `super` getters, nested constructions, blocks, the fields' scope
{
  var y = "outer";
  class A {
    constructor(a) { log.push("A"); this.a = a; }
    get tag() { return "tag of " + this.a; }
    set mark(v) { this.marked = v; }
  }
  show("super getter in the constructor after the arrow", () => {
    class B extends A { constructor() { (() => super(1))(); this.r = super.tag; } }
    return new B().r;
  });
  show("super getter in the arrow after super()", () => {
    class B extends A { constructor() { (() => { super(2); this.r = super.tag; })(); } }
    return new B().r;
  });
  show("super getter after an arrow called through a builtin", () => {
    class B extends A { constructor() { [3].forEach((v) => super(v)); this.r = super.tag; } }
    return new B().r;
  });
  show("super setter in the constructor after the arrow", () => {
    class B extends A { constructor() { (() => super(1))(); super.mark = "m"; } }
    return new B().marked;
  });
  show("arrow made in a block with a captured let", () => {
    class B extends A { constructor() { { let z = 4; (() => { super(z); })(); } this.b = this.a + 1; } }
    return new B().b;
  });
  show("arrow made in a loop", () => {
    class B extends A { constructor() { for (let i = 0; i < 3; i++) { if (i == 1) (() => super(i))(); } } }
    return new B().a;
  });
  show("parameter default calls the arrow at once", () => {
    class B extends A { constructor(v = (() => super(5))()) { this.same = v === this; } }
    return new B().same;
  });
  show("returns a number after the arrow's super()", () => {
    class B extends A { constructor() { (() => super())(); return 1; } }
    return new B();
  });
  show("returns an object after the arrow's super()", () => {
    class B extends A { constructor() { (() => super())(); return { other: 1 }; } }
    return new B().other;
  });
  show("the outer construction's arrow called inside an inner one", () => {
    log = [];
    class B extends A {
      constructor(g) {
        const f = () => super(g ? "inner" : "outer");
        if (g) { g(); f(); this.kind = "inner"; } else { const made = new B(f); this.made = made; this.kind = "outer"; }
      }
    }
    const b = new B();
    return [b.a, b.kind, b.made.a, b.made.kind, b.made !== b].join();
  });
  show("the same class constructed inside before the arrow runs", () => {
    class B extends A {
      constructor(n) {
        const f = () => super(n);
        const inner = n > 0 ? new B(n - 1) : null;
        f();
        this.inner = inner;
      }
    }
    const b = new B(2);
    return [b.a, b.inner.a, b.inner.inner.a, b.inner.inner.inner].join();
  });
  show("a field initializer throws in the arrow's super()", () => {
    class B extends A {
      x = (() => { throw new RangeError("field"); })();
      constructor() { try { (() => super(1))(); } catch (e) { this.caught = e.constructor.name; } }
    }
    const b = new B();
    return [b.caught, b.a, "x" in b].join();
  });
  show("field initializer's scope", () => {
    class B extends A { x = y; f = () => y; t = new.target; constructor(y) { (() => super())(); } }
    const b = new B("param");
    return [b.x, b.f(), b.t].join();
  });
  show("field initializers run in order, once", () => {
    var order = [];
    class B extends A { p = order.push("p"); q = order.push("q"); constructor() { const f = () => super(); f(); try { f(); } catch (e) { order.push(e.constructor.name); } } }
    new B();
    return order.join();
  });
  show("computed and private fields", () => {
    const k = "key";
    class B extends A { [k] = 1; #p = 2; static has(o) { return #p in o; } constructor() { (() => super())(); } }
    const b = new B();
    return [b.key, B.has(b)].join();
  });
  show("accessor and method on the instance after the arrow", () => {
    class B extends A { constructor() { (() => super(6))(); } get twice() { return this.a * 2; } }
    return new B().twice;
  });
  show("a subclass with its own fields", () => {
    class B extends A { b = 1; constructor() { (() => super())(); } }
    class C extends B { c = this.b + 1; }
    const c = new C();
    return [c.b, c.c, c instanceof C].join();
  });
  show("an unrelated arrow reads this before and after", () => {
    log = [];
    class B extends A {
      constructor() {
        const read = () => this;
        try { read(); } catch (e) { log.push(e.constructor.name); }
        (() => super())();
        log.push(read() === this);
      }
    }
    new B();
    return log.join();
  });
  show("many constructions", () => {
    class B extends A { x = 1; constructor(i) { (() => super(i))(); } }
    var sum = 0;
    for (var i = 0; i < 2000; i++) { const b = new B(i); sum += b.a + b.x; }
    return sum;
  });
}
