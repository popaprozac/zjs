// Subclasses of Array: `new`, Array.from and Array.of called on the
// subclass, and the methods that make their result through the
// receiver's species all hand back instances of the subclass, which are
// still arrays. The new target decides the prototype (Reflect.construct,
// a bound constructor), read before the length is checked. from and of
// construct any receiver that is a constructor, before the items are
// read, then define the elements and set the length. An instance keeps
// its class alive through a collection.
function churn() { var keep = []; for (var i = 0; i < 300; i++) { keep.push({ a: i, b: [i], c: "s" + i }); } return keep.length; }
function collect() { gc(); churn(); gc(); churn(); }
function show(label, f) { try { console.log(label, JSON.stringify(f())); } catch (e) { console.log(label, "throws", e && e.constructor ? e.constructor.name : e); } }

class Stack extends Array {
  peek() { return this[this.length - 1]; }
  get depth() { return this.length; }
  static make() { return new this(); }
}
class Loud extends Array {
  push() { Loud.calls++; return super.push.apply(this, arguments); }
  join(separator) { return "<" + super.join(separator === undefined ? "," : separator) + ">"; }
}
Loud.calls = 0;
class Named extends Array {
  label = "unset";
  count = this.length;
  #secret = 42;
  constructor(label, ...items) { super(...items); this.label = label; }
  secret() { return this.#secret; }
}
class Deep extends Stack {
  peek() { return "deep " + super.peek(); }
}

// --- new ---
show("new:", function () { var s = new Stack(); var t = new Stack(3); var u = new Stack(1, 2, 3); var v = new Stack("x"); return [s instanceof Stack, s instanceof Array, Array.isArray(s), s.length, t.length, 0 in t, u.join(), v.length, v[0], Object.getPrototypeOf(u) === Stack.prototype, u.constructor === Stack, Object.prototype.toString.call(u)]; });
show("new with a negative length:", function () { return new Stack(-1); });
show("new with a fractional length:", function () { return new Stack(1.5); });
show("called without new:", function () { return Stack(); });
show("push, pop, and length:", function () { var s = new Stack(); var r = [s.push(1, 2, 3), s.length, s.pop(), s.length]; s[5] = "far"; r.push(s.length, 4 in s); s.length = 1; r.push(s.join(), s instanceof Stack, s); return r; });
show("own keys:", function () { var s = new Stack(7, 8); s.extra = 1; var seen = []; for (var k in s) seen.push(k); return [Object.keys(s), Object.getOwnPropertyNames(s), Reflect.ownKeys(s).length, seen, s]; });
show("statics the subclass inherits:", function () { return [Stack.from === Array.from, Stack.of === Array.of, Stack.isArray === Array.isArray, Stack.name, Stack.length, Object.getPrototypeOf(Stack) === Array, Stack[Symbol.species] === Stack, Stack.make() instanceof Stack]; });

// --- from and of ---
show("from an array:", function () { var a = Stack.from([1, 2, 3]); return [a instanceof Stack, Array.isArray(a), a.length, a, a.peek()]; });
show("from other iterables:", function () { function* three() { yield "a"; yield "b"; yield "c"; } var a = Stack.from(new Set([4, 5, 4])); var b = Stack.from("hey"); var c = Stack.from(three()); return [a instanceof Stack, a, b instanceof Stack, b, c instanceof Stack, c]; });
show("from an array-like:", function () { var a = Stack.from({ length: 3, 0: "p", 2: "r" }); return [a instanceof Stack, a.length, a, 1 in a]; });
show("from with a mapping function:", function () { var a = Stack.from([1, 2, 3], function (x, i) { return x * this.k + i; }, { k: 10 }); return [a instanceof Stack, a]; });
show("from nothing:", function () { return Stack.from(null); });
show("from with a mapping that is not a function:", function () { return Stack.from([], 1); });
show("of:", function () { var a = Stack.of(1, 2, 3); var b = Stack.of(7); var c = Stack.of(); return [a instanceof Stack, a, b instanceof Stack, b.length, b, c instanceof Stack, c.length]; });
show("from constructs before it reads the items:", function () {
  var log = [];
  class Logged extends Array { constructor(...given) { log.push("construct " + given.join()); super(...given); } }
  Logged.from({ [Symbol.iterator]() { log.push("iterate"); return [1, 2][Symbol.iterator](); } });
  Logged.from({ get length() { log.push("length"); return 2; }, 0: "a", 1: "b" });
  Logged.of(1, 2, 3);
  return log;
});
show("from when the constructor throws:", function () { var touched = false; try { Array.from.call(function () { throw new EvalError("no"); }, { [Symbol.iterator]() { touched = true; return [][Symbol.iterator](); } }); } catch (e) { return [e.constructor.name, touched]; } return "no throw"; });
show("from and of set the length:", function () { class Padded extends Array { constructor() { super(5); } } var p = Padded.from([1, 2]); var q = Padded.of(1, 2, 3); return [p instanceof Padded, p.length, p, q.length, q]; });
show("from and of define, they do not assign:", function () {
  var log = [];
  class Trap extends Array {}
  Object.defineProperty(Trap.prototype, "1", { get: function () { return "inherited"; }, set: function (v) { log.push("set " + v); } });
  var t = Trap.of("a", "b"); var f = Trap.from(["c", "d"]);
  var r = [t, f, t.hasOwnProperty(1), log.length];
  var u = new Trap(); u.push("x", "y");
  r.push(log, u.length, u[1], u.hasOwnProperty(1));
  return r;
});
show("from and of on a constructor that is not a subclass:", function () {
  function Box(n) { this.made = arguments.length ? n : "no arguments"; }
  var a = Array.from.call(Box, ["x", "y"]); var b = Array.from.call(Box, { length: 2, 0: "p", 1: "q" }); var c = Array.of.call(Box, 7, 8, 9);
  return [a instanceof Box, Array.isArray(a), a.made, a[0], a[1], a.length, b.made, b[1], b.length, c instanceof Box, c.made, c[2], c.length];
});
show("from and of on a receiver that is not a constructor:", function () { var a = Array.from.call({}, [1]); var b = Array.of.call(undefined, 1, 2); var c = Array.from.call(function () { return 1; }.bind, "ab"); var d = Array.of.call(Math.max, 3); var e = Array.from.call(() => 1, [4]); return [Array.isArray(a), a, Array.isArray(b), b, Array.isArray(c), c, Array.isArray(d), d, Array.isArray(e), e]; });
show("of on an object that takes no elements:", function () { return Array.of.call(function () { return Object.freeze({}); }, 1); });
show("of on an object whose element is fixed:", function () { return Array.of.call(function () { Object.defineProperty(this, "0", { value: 1, configurable: false }); }, 2); });
show("from on an object whose length is fixed:", function () { return Array.from.call(function () { Object.defineProperty(this, "length", { value: 0, writable: false }); }, []); });

// --- methods ---
show("inherited and added methods:", function () { var s = Stack.of(3, 1, 2); var seen = []; for (var x of s) seen.push(x); return [s.peek(), s.depth, s.indexOf(1), s.includes(2), s.sort() === s, s.join(), s.reverse() === s, s.join("-"), seen, [...s], s.reduce(function (a, b) { return a + b; }, 0), s.entries().next().value]; });
show("overridden methods:", function () { var l = new Loud(); l.push("a"); l.push("b", "c"); var r = [Loud.calls, l.length, l.join(), l.join("+"), String(l), "" + l, Array.prototype.join.call(l)]; Array.prototype.push.call(l, "d"); r.push(Loud.calls, l.length); return r; });
show("one site, plain and subclass receivers:", function () { function add(a, v) { return a.push(v); } function text(a) { return a.join("-"); } var plain = []; var loud = new Loud(); var stack = new Stack(); var before = Loud.calls; var r = []; for (var i = 0; i < 6; i++) { add(plain, i); add(loud, i); add(stack, i); } r.push(Loud.calls - before, text(plain), text(loud), text(stack)); return r; });
show("a constructor and fields of its own:", function () { var n = new Named("first", 1, 2, 3); var e = new Named("empty"); return [n instanceof Named, n.label, n.count, n.secret(), n.length, n, e.label, e.length, Object.keys(n)]; });
show("this before super:", function () { class Early extends Array { constructor() { this.x = 1; super(); } } return new Early(); });
show("a subclass of a subclass:", function () { var d = new Deep(1, 2); d.push(3); var e = Deep.from("xy"); var f = Deep.of(9); return [d instanceof Deep, d instanceof Stack, d instanceof Array, Array.isArray(d), d.peek(), d.depth, e instanceof Deep, e.peek(), f instanceof Deep, f.peek(), Object.getPrototypeOf(Deep) === Stack, Deep.make() instanceof Deep]; });

// --- species ---
show("species:", function () { var s = Stack.of(1, 2, 3, 4); var parts = [s.slice(1), s.concat([5]), s.map(function (x) { return x * 2; }), s.filter(function (x) { return x % 2 == 0; }), s.splice(1, 2), Stack.of([1], [2, [3]]).flat(), s.flatMap(function (x) { return [x, x]; })]; return [parts.map(function (p) { return p instanceof Stack; }), parts, s, s.slice(1).peek()]; });
show("species of a subclass of a subclass:", function () { var d = Deep.of(1, 2, 3); var m = d.map(function (x) { return x + 1; }); var f = d.filter(function (x) { return x > 1; }); return [m instanceof Deep, m.peek(), f instanceof Deep, f, d.slice(0, 1).constructor === Deep, d.concat(d).length]; });
show("species runs the subclass's constructor:", function () { var n = new Named("n", 1, 2, 3); var m = n.map(function (x) { return x * 2; }); var f = n.filter(function (x) { return x > 5; }); return [m instanceof Named, m, m.label, m.count, m.secret(), f instanceof Named, f.label, f.length]; });
show("species overridden:", function () { class Plain extends Array { static get [Symbol.species]() { return Array; } } var p = Plain.of(1, 2); var m = p.map(function (x) { return x; }); return [p instanceof Plain, m instanceof Plain, m.constructor === Array, p.slice().constructor === Array, m]; });
show("species null and undefined:", function () { class None extends Array { static get [Symbol.species]() { return null; } } var a = None.of(1, 2).map(function (x) { return x; }); var s = Stack.of(1, 2); s.constructor = undefined; var b = s.filter(function () { return true; }); return [a.constructor === Array, a, b instanceof Stack, Object.getPrototypeOf(b) === Array.prototype, b]; });
show("species that is not a constructor:", function () { class Bad extends Array { static get [Symbol.species]() { return 1; } } return Bad.of(1).map(function (x) { return x; }); });
show("constructor that is not an object:", function () { var s = Stack.of(1); s.constructor = 5; return s.slice(); });
show("methods that always make a plain array:", function () { var s = Stack.of(3, 1, 2); var made = [s.toSorted(), s.toReversed(), s.toSpliced(0, 1), s.with(0, 9), Array.from(s), [...s], [0].concat(s, [4])]; return [made.map(function (m) { return m instanceof Stack; }), made]; });

// --- the new target ---
show("Reflect.construct:", function () {
  function Bare() {} function NoProto() {} NoProto.prototype = null;
  var a = Reflect.construct(Array, [1, 2], Stack); var b = Reflect.construct(Stack, [1, 2], Array); var c = Reflect.construct(Array, [3], Bare); var d = Reflect.construct(Array, [], NoProto);
  return [a instanceof Stack, a.peek(), b instanceof Stack, Object.getPrototypeOf(b) === Array.prototype, b, Object.getPrototypeOf(c) === Bare.prototype, Array.isArray(c), c.length, typeof c.push, Object.getPrototypeOf(d) === Array.prototype];
});
show("Reflect.construct with a bad length:", function () { return Reflect.construct(Array, [-1], Stack); });
show("bound constructors:", function () { var Bound = Stack.bind(null, 1, 2); var s = new Bound(3); var t = Reflect.construct(Array, [1], Bound); return [s instanceof Stack, s instanceof Bound, s, Object.getPrototypeOf(t) === Array.prototype]; });
show("prototype is read before the length is checked:", function () { var log = []; var target = function () {}.bind(); Object.defineProperty(target, "prototype", { get: function () { log.push("prototype"); return Stack.prototype; } }); try { Reflect.construct(Array, [-1], target); } catch (e) { log.push(e.constructor.name); } var made = Reflect.construct(Array, [1, 2], target); log.push(made instanceof Stack, made.length); return log; });
show("a subclass written without class:", function () {
  function Old() { return Reflect.construct(Array, arguments, new.target); }
  Object.setPrototypeOf(Old, Array);
  Old.prototype = Object.create(Array.prototype, { constructor: { value: Old, writable: true, configurable: true }, first: { get: function () { return this[0]; } } });
  var o = new Old(4, 5); var m = o.map(function (x) { return x + 1; });
  return [o instanceof Old, o.first, o.length, m instanceof Old, m.first, Old.from([9]).first, Old.of(8) instanceof Old];
});
show("an array given the prototype afterwards:", function () { var s = [1, 2, 3]; Object.setPrototypeOf(s, Stack.prototype); return [s instanceof Stack, s.peek(), s.slice(1) instanceof Stack, s.map(function (x) { return x; }) instanceof Stack]; });

// --- collection ---
function fresh() { class Temp extends Array { get tag() { return "temp " + this.length; } } return new Temp(1, 2, 3); }
show("an instance keeps its class through a collection:", function () { var t = fresh(); collect(); var m = t.map(function (x) { collect(); return x * 2; }); collect(); return [t.tag, m.tag, m.constructor.name, m]; });
show("a prototype nothing else holds:", function () { var target = function () {}.bind(); Object.defineProperty(target, "prototype", { get: function () { collect(); return Object.create(Array.prototype, { tag: { value: "fresh" } }); } }); var a = Reflect.construct(Array, [1, 2, 3], target); collect(); return [a.tag, a.length, a, Array.isArray(a)]; });
show("collecting while from and of fill:", function () {
  class Slow extends Array { constructor(...given) { collect(); super(...given); } }
  var a = Slow.from(new Set([{ v: 1 }, { v: 2 }]), function (x) { collect(); return { w: x.v }; }); var b = Slow.of({ v: 3 }, { v: 4 }); var c = Slow.from({ length: 2, get 0() { collect(); return { v: 5 }; }, 1: { v: 6 } });
  collect();
  return [a instanceof Slow, a, b instanceof Slow, b, c instanceof Slow, c];
});
