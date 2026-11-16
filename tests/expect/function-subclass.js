// Subclasses of Function: `new` on the subclass hands back a function
// that inherits from the subclass's prototype and is still callable.
// The new target decides the prototype (Reflect.construct, a bound
// constructor), read only once the source has compiled. An instance
// keeps its class alive through a collection.
function churn() { var keep = []; for (var i = 0; i < 300; i++) { keep.push({ a: i, b: [i], c: "s" + i }); } return keep.length; }
function collect() { gc(); churn(); gc(); churn(); }
function show(label, f) { try { console.log(label, JSON.stringify(f())); } catch (e) { console.log(label, "throws", e && e.constructor ? e.constructor.name : e); } }

class Fn extends Function {
  twice(x) { return this(this(x)); }
  get arity() { return this.length; }
  static make(body) { return new this(body); }
}
class Named extends Function {
  label = "unset";
  #secret = 42;
  constructor(label, ...source) { super(...source); this.label = label; }
  secret() { return this.#secret; }
}
class Deep extends Fn {
  twice(x) { return "deep " + super.twice(x); }
}

// --- new ---
show("new:", function () { var f = new Fn("a", "b", "return a + b"); return [f instanceof Fn, f instanceof Function, typeof f, f(2, 3), f.length, f.name, Object.getPrototypeOf(f) === Fn.prototype, f.constructor === Fn, Object.prototype.toString.call(f)]; });
show("new with no source:", function () { var f = new Fn(); return [f instanceof Fn, f(), f.length]; });
show("new with a body that does not parse:", function () { return new Fn("}"); });
show("called without new:", function () { return Fn("return 1"); });
show("statics the subclass inherits:", function () { return [Fn.name, Fn.length, Object.getPrototypeOf(Fn) === Function, Fn.make("return 7") instanceof Fn, Fn.make("return 7")()]; });
show("own keys:", function () { var f = new Fn("a", "return a"); f.extra = 1; return [Object.keys(f), Object.getOwnPropertyNames(f).sort(), f.hasOwnProperty("prototype")]; });

// --- methods ---
show("inherited and added methods:", function () { var f = new Fn("x", "return x * 3"); return [f.twice(2), f.arity, f.call(null, 4), f.apply(null, [5]), f.bind(null, 6)(), typeof f.toString()]; });
show("a bound instance:", function () { var f = new Fn("a", "b", "return a - b"); var b = f.bind(null, 10); return [b instanceof Fn, b(4), b.twice === Fn.prototype.twice, Object.getPrototypeOf(b) === Fn.prototype]; });
show("an instance as a constructor:", function () { var Made = new Fn("v", "this.v = v"); var m = new Made(8); return [m.v, m instanceof Made, Object.getPrototypeOf(Made.prototype) === Object.prototype, Made.prototype.constructor === Made]; });
show("a constructor and fields of its own:", function () { var n = new Named("adder", "a", "b", "return a + b"); return [n instanceof Named, n.label, n.secret(), n(1, 2), n.length, Object.keys(n)]; });
show("this before super:", function () { class Early extends Function { constructor() { this.x = 1; super(); } } return new Early(); });
show("a subclass of a subclass:", function () { var d = new Deep("x", "return x + 1"); return [d instanceof Deep, d instanceof Fn, d instanceof Function, d.twice(1), d.arity, Object.getPrototypeOf(Deep) === Fn, Deep.make("return 2") instanceof Deep]; });

// --- the new target ---
show("Reflect.construct:", function () {
  function Bare() {} function NoProto() {} NoProto.prototype = null;
  var a = Reflect.construct(Function, ["return 1"], Fn); var b = Reflect.construct(Fn, ["return 2"], Function); var c = Reflect.construct(Function, ["return 3"], Bare); var d = Reflect.construct(Function, ["return 4"], NoProto);
  return [a instanceof Fn, a(), b instanceof Fn, Object.getPrototypeOf(b) === Function.prototype, b(), Object.getPrototypeOf(c) === Bare.prototype, typeof c, typeof c.call, Function.prototype.call.call(c), Object.getPrototypeOf(d) === Function.prototype, d()];
});
show("bound constructors:", function () { var Bound = Fn.bind(null, "a"); var f = new Bound("return a * 2"); var g = Reflect.construct(Function, ["return 5"], Bound); return [f instanceof Fn, f instanceof Bound, f(4), Object.getPrototypeOf(g) === Function.prototype, g()]; });
show("prototype is read once the source has compiled:", function () { var log = []; var target = function () {}.bind(); Object.defineProperty(target, "prototype", { get: function () { log.push("prototype"); return Fn.prototype; } }); try { Reflect.construct(Function, ["}"], target); } catch (e) { log.push(e.constructor.name); } var made = Reflect.construct(Function, [{ toString: function () { log.push("source"); return "return 6"; } }], target); log.push(made instanceof Fn, made()); return log; });
show("Function itself:", function () { var f = new Function("a", "return a + 1"); var g = Function("return 9"); return [Object.getPrototypeOf(f) === Function.prototype, f(1), Object.getPrototypeOf(g) === Function.prototype, g(), f instanceof Fn]; });

// --- collection ---
function fresh() { class Temp extends Function { get tag() { return "temp " + this.length; } } return new Temp("a", "b", "return a * b"); }
show("an instance keeps its class through a collection:", function () { var t = fresh(); collect(); return [t.tag, t(3, 4), t.constructor.name]; });
show("a prototype nothing else holds:", function () { var target = function () {}.bind(); Object.defineProperty(target, "prototype", { get: function () { collect(); return Object.create(Function.prototype, { tag: { value: "fresh" } }); } }); var f = Reflect.construct(Function, ["a", "return a + 1"], target); collect(); return [f.tag, f(1), typeof f]; });
show("collecting while the source is read:", function () { var f = new Fn({ toString: function () { collect(); return "a"; } }, { toString: function () { collect(); return "return [a, typeof this.twice]"; } }); collect(); return [f instanceof Fn, f.call(f, 1)]; });
