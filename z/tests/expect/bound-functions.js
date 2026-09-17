// Bound functions: a call uses boundThis and a construct ignores it,
// decided by how the function was entered and never by the shape of
// `this`; both prepend the bound arguments; the new target becomes the
// target only when it was the bound function itself; there is no own
// `prototype` unless the program defines one; instanceof asks the
// target, custom @@hasInstance included.
function show(label, f) { try { console.log(label, String(f())); } catch (e) { console.log(label, "throws", e && e.constructor ? e.constructor.name : e); } }
function churn() { var keep = []; for (var i = 0; i < 300; i++) { keep.push({ a: i, b: [i], c: "s" + i }); } return keep.length; }
function collect() { gc(); churn(); gc(); churn(); }
function F(a, b) { this.a = a; this.b = b; this.nt = new.target; }
var B = F.bind({ bt: 1 }, 1);

// --- call versus construct ---
show("construct ignores boundThis:", function () { var x = new B(2); return [x.a, x.b, x.nt === F, x.bt, Object.getPrototypeOf(x) === F.prototype]; });
show("call uses boundThis:", function () { var t = {}; var C = F.bind(t, 5); C.call({}, 6); return [t.a, t.b, t.nt]; });
show("call with a this shaped like an instance:", function () { var t = {}; var C = F.bind(t, 5); var fake = Object.create(F.prototype); C.call(fake, 6); return [t.a, fake.a]; });
show("call returns the target's result:", function () { function g(a, b) { return [this.k, a, b].join(); } return g.bind({ k: "k" }, 1)(2); });
show("construct returns the target's object result:", function () { var other = { other: true }; function g() { return other; } return new (g.bind())() === other; });
show("arguments are prepended in order:", function () { function g() { return Array.prototype.join.call(arguments); } var b = g.bind(null, 1, 2).bind(null, 3); var C = (function () { this.args = Array.prototype.join.call(arguments); }).bind(null, "x", "y"); return [b(4, 5), new C("z").args]; });

// --- constructability follows the target ---
show("bound arrow:", function () { return new ((() => 1).bind())(); });
show("bound class method:", function () { class K { m() {} } return new (K.prototype.m.bind())(); });
show("bound generator and async:", function () { var r = []; [function* () {}, async function () {}].forEach(function (f) { try { new (f.bind())(); r.push("no throw"); } catch (e) { r.push(e.constructor.name); } }); return r; });
show("bound builtin non-constructor:", function () { return new (Math.max.bind())(); });
show("bound class called:", function () { class K {} return K.bind(null)(); });
show("bound builtins construct:", function () { return [new (Map.bind())([[1, 2]]).get(1), new (Array.bind(null, 3))().length, new (Date.bind(null, 2020, 1))().getFullYear(), new (RangeError.bind(null, "m"))().message, new (RangeError.bind(null, "m"))() instanceof RangeError]; });

// --- new target ---
show("Reflect.construct, distinct new target:", function () { function N() {} var x = Reflect.construct(B, [9], N); return [x.nt === N, Object.getPrototypeOf(x) === N.prototype, x.a, x.b]; });
show("nested bindings:", function () { var BB = B.bind(null, 7); var y = new BB(8); return [y.a, y.b, y.nt === F, y instanceof BB, y instanceof B, y instanceof F]; });
show("Reflect.construct, new target is the inner binding:", function () { var BB = B.bind(null, 7); var x = Reflect.construct(BB, [], B); return [x.nt === B, x.nt === F]; });
show("Reflect.construct, new target is the outer binding:", function () { var BB = B.bind(null, 7); var x = Reflect.construct(B, [], BB); return [x.nt === BB, x.nt === F]; });
show("bound class:", function () { class K { constructor(v) { this.v = v; this.nt = new.target; } } var BK = K.bind(null, 3); var k = new BK(); return [k.v, k.nt === K, k instanceof K, k instanceof BK]; });
show("bound derived class:", function () { class A { constructor() { this.nt = new.target; } } class K extends A {} var BK = K.bind(); var k = new BK(); return [k.nt === K, k instanceof A, Object.getPrototypeOf(BK) === A]; });
show("a class re-parented to a binding:", function () { class A {} class D extends A { constructor() { super("x"); } } function T(a, b) { this.got = [a, b].join(); this.nt = new.target === D; } Object.setPrototypeOf(D, T.bind(null, "bound")); var d = new D(); return [d.got, d.nt, d instanceof D]; });
show("class extends a binding without prototype:", function () { class D extends B {} return new D(); });
show("class extends a binding given a prototype:", function () { var C = F.bind(null, 1); C.prototype = F.prototype; class D extends C { constructor() { super(2); } } var d = new D(); return [d.a, d.b, d.nt === D, d instanceof D, d instanceof F]; });
show("bound Promise:", function () { var BP = Promise.bind(); var p = new BP(function (r) { r(1); }); return [p instanceof Promise, p instanceof BP, Object.getPrototypeOf(p) === Promise.prototype]; });
show("bound Promise called:", function () { return Promise.bind()(function () {}); });

// --- the [[Prototype]] and the `prototype` property ---
show("no own prototype:", function () { return ["prototype" in B, B.hasOwnProperty("prototype"), typeof B.prototype, Object.getOwnPropertyNames(B).sort().join()]; });
show("an assigned prototype is an ordinary property:", function () { var C = F.bind(); C.prototype = { p: 1 }; var d = Object.getOwnPropertyDescriptor(C, "prototype"); return [d.writable, d.enumerable, d.configurable, C.prototype.p, new C() instanceof C, Object.getPrototypeOf(new C()) === F.prototype, delete C.prototype, "prototype" in C]; });
show("a defined prototype getter is not read by construction:", function () { var C = F.bind(); var n = 0; Object.defineProperty(C, "prototype", { get: function () { n++; collect(); return F.prototype; }, configurable: true }); var x = new C(); return [n, x instanceof F, n]; });
show("inherits what the target inherits:", function () { function P() {} function T() {} Object.setPrototypeOf(T, P); var N = function () {}; Object.setPrototypeOf(N, null); return [Object.getPrototypeOf(T.bind()) === P, Object.getPrototypeOf(F.bind()) === Function.prototype, Object.getPrototypeOf(Function.prototype.bind.call(N))]; });

// --- instanceof ---
show("custom hasInstance on the target:", function () { function T() {} Object.defineProperty(T, Symbol.hasInstance, { value: function (v) { collect(); return v === 42; } }); var BT = T.bind(); return [42 instanceof BT, {} instanceof BT, new T() instanceof BT, 42 instanceof BT.bind()]; });
show("hasInstance getter on the target is read each time:", function () { var n = 0; function T() {} Object.defineProperty(T, Symbol.hasInstance, { get: function () { n++; return undefined; } }); var BT = T.bind(); var r = [new T() instanceof BT, {} instanceof BT]; return r.concat(n); });
show("binding of a non-constructor:", function () { return {} instanceof (() => 1).bind(); });
show("Function.prototype[@@hasInstance] directly:", function () { var h = Function.prototype[Symbol.hasInstance]; return [h.call(B, new F()), h.call(B, {}), h.call({}, {}), h.call(B.bind(), new F())]; });
show("own hasInstance on the binding itself:", function () { var C = F.bind(); Object.defineProperty(C, Symbol.hasInstance, { value: function () { return "yes"; } }); return 1 instanceof C; });
show("target prototype undefined:", function () { function T() {} T.prototype = undefined; return {} instanceof T.bind(); });
show("prototype undefined, unbound:", function () { function T() {} T.prototype = undefined; return {} instanceof T; });
show("primitive left side, bad prototype:", function () { function T() {} T.prototype = 3; return 1 instanceof T; });
show("a function in the value's chain:", function () { function F() {} var o = Object.create(F); function G() {} G.prototype = F; return [o instanceof G, o instanceof Function, o instanceof Object]; });
show("not callable:", function () { return {} instanceof {}; });
show("builtin without prototype:", function () { return {} instanceof Math.max; });
show("a binding's own prototype is not consulted:", function () { var n = 0; var T = (function () {}).bind(); Object.defineProperty(T, "prototype", { get: function () { n++; return Array.prototype; } }); return [[] instanceof T, n]; });
show("the target's prototype getter is read, once per test:", function () { var n = 0; var target = () => {}; Object.defineProperty(target, "prototype", { get: function () { n++; collect(); return Array.prototype; } }); var T = target.bind().bind(); return [[] instanceof T, {} instanceof T, n]; });
show("the target's prototype getter throws:", function () { var target = () => {}; Object.defineProperty(target, "prototype", { get: function () { throw new RangeError("p"); } }); return [] instanceof target.bind(); });

// --- name and length ---
show("name and length:", function () { function g(a, b, c) {} var b = g.bind(null, 1); var dn = Object.getOwnPropertyDescriptor(b, "name"), dl = Object.getOwnPropertyDescriptor(b, "length"); return [b.name, b.length, dn.writable, dn.enumerable, dn.configurable, dl.writable, dl.enumerable, dl.configurable, g.bind(null, 1, 2, 3, 4).length]; });
show("length forms:", function () { function g() {} var r = []; [Infinity, -Infinity, 2.7, -3, "5", NaN, 2147483648, 4294967296.5, undefined, null, true, {}].forEach(function (v) { Object.defineProperty(g, "length", { value: v, configurable: true }); r.push(g.bind().length); }); Object.defineProperty(g, "length", { value: Infinity, configurable: true }); r.push(g.bind(null, 1, 2).length); return r; });
show("length must be own:", function () { function g(a, b) {} delete g.length; var bind = Function.prototype.bind; var r = [bind.call(g).length]; Object.setPrototypeOf(g, { length: 7 }); r.push(bind.call(g).length, g.length); return r; });
show("name forms:", function () { function g() {} var r = []; [undefined, 5, Symbol("s"), "str", {}].forEach(function (v) { Object.defineProperty(g, "name", { value: v, configurable: true }); r.push(JSON.stringify(g.bind().name)); }); return r; });
show("reads in order, once each:", function () { var log = []; function g() {} Object.defineProperty(g, "length", { get: function () { log.push("length"); collect(); return 2; }, configurable: true }); Object.defineProperty(g, "name", { get: function () { log.push("name"); collect(); return "n"; }, configurable: true }); var b = g.bind(null, 1); return [log.join(), b.name, b.length]; });
show("a throwing name getter:", function () { function g() {} Object.defineProperty(g, "name", { get: function () { throw new RangeError("n"); } }); return g.bind(); });
show("a throwing length getter:", function () { function g() {} Object.defineProperty(g, "length", { get: function () { throw new EvalError("l"); } }); return g.bind(); });
show("names of bindings of bindings, classes, symbols:", function () { function g() {} var s = Symbol("desc"); class K { static [s]() {} } return [g.bind().bind().name, K.bind().name, JSON.stringify(K[s].bind().name), (() => {}).bind().name === "bound "]; });
show("bind on a non-callable:", function () { return Function.prototype.bind.call({}); });

// --- collections forced inside constructors reached through bindings ---
show("collections inside bound construction:", function () {
  function Heavy(a, b) { collect(); this.a = a; this.b = b; this.list = [a, b]; collect(); }
  var BH = Heavy.bind({ ignored: true }, { first: 1 });
  var BBH = BH.bind(null, { second: 2 });
  function N() {}
  var x = new BBH(), y = Reflect.construct(BBH, [], N);
  return [JSON.stringify(x), x instanceof BBH, JSON.stringify(y), Object.getPrototypeOf(y) === N.prototype];
});
