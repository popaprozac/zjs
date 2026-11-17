// Bound functions whose targets are bound functions. A name is "bound "
// and the target's name as it was when `bind` read it, however long the
// chain and whatever happens to the target's name afterwards; a call or
// a construct goes down the chain to the first target that is not
// bound, with every link's arguments in order, the innermost `this`,
// and the new target moved down from each link it names; and a long
// chain is called without running out of stack.
function show(label, f) { try { console.log(label, String(f())); } catch (e) { console.log(label, "throws", e && e.constructor ? e.constructor.name : e); } }
function churn() { var keep = []; for (var i = 0; i < 300; i++) { keep.push({ a: i, b: [i], c: "s" + i }); } return keep.length; }
function collect() { gc(); churn(); gc(); churn(); }
function chainOf(f, n) { for (var i = 0; i < n; i++) f = f.bind(null); return f; }
// A chain whose links are renamed, so that each name is short whatever
// the engine does with names.
function renamedChainOf(f, n) { for (var i = 0; i < n; i++) { f = f.bind(null); Object.defineProperty(f, "name", { value: "link" }); } return f; }

// --- names ---
show("names by depth:", function () { function g() {} return [g.bind().name, g.bind().bind().name, g.bind().bind().bind().name, chainOf(g, 7).name]; });
show("a long name:", function () { var f = function () {}; var n = chainOf(f, 2000).name; return [n.length, n.slice(0, 13), n.slice(-13), n === new Array(2001).join("bound ") + "f"]; });
show("name descriptor:", function () { function g() {} var b = chainOf(g, 3); var d = Object.getOwnPropertyDescriptor(b, "name"); return [d.value, d.writable, d.enumerable, d.configurable, Object.getOwnPropertyNames(b).sort(), b.hasOwnProperty("name")]; });
show("the same name each read:", function () { function g() {} var b = chainOf(g, 4); return [b.name === b.name, b.name, b.name.length]; });
show("a wide name:", function () { var o = { "中文": function () {} }; var n = chainOf(o["中文"], 3).name; return [n.length, n.charCodeAt(18), n.charCodeAt(19), n.slice(0, 18)]; });
show("an anonymous target:", function () { return JSON.stringify(chainOf(function () {}, 3).name); });
show("a builtin target:", function () { return [chainOf(Math.max, 2).name, chainOf(Map, 3).name]; });
show("the target renamed afterwards:", function () { function g() {} var b1 = g.bind(); Object.defineProperty(g, "name", { value: "h" }); var b2 = b1.bind(); return [b1.name, b2.name, g.bind().name]; });
show("a link renamed afterwards:", function () { function g() {} var b1 = g.bind(), b2 = b1.bind(), b3 = b2.bind(); Object.defineProperty(b1, "name", { value: "x" }); Object.defineProperty(b2, "name", { value: "y" }); return [b1.name, b2.name, b3.name, b3.bind().name, b2.bind().name, b1.bind().bind().name]; });
show("a link's name deleted:", function () { function g() {} var b1 = g.bind(), b2 = b1.bind(); delete b1.name; var b3 = b1.bind(); return [JSON.stringify(b1.name), b2.name, JSON.stringify(b3.name), JSON.stringify(b3.bind().name), b1.hasOwnProperty("name")]; });
show("a link's name deleted and inherited:", function () { function g() {} var bind = Function.prototype.bind; var b1 = g.bind(); delete b1.name; Object.setPrototypeOf(b1, { name: "proto" }); var b2 = bind.call(b1); return [b1.name, b2.name, bind.call(b2).name, b2.hasOwnProperty("name")]; });
show("a link's name redefined and deleted:", function () { function g() {} var b1 = g.bind(); Object.defineProperty(b1, "name", { value: "x", configurable: true }); delete b1.name; return [JSON.stringify(b1.name), JSON.stringify(b1.bind().name)]; });
show("a link's name a getter, read once a bind:", function () { function g() {} var n = 0; var b1 = g.bind(); Object.defineProperty(b1, "name", { get: function () { n++; collect(); return "got" + n; } }); var b2 = b1.bind(), b3 = b2.bind(), b4 = b1.bind(); return [b2.name, b3.name, b4.name, n]; });
show("a link's name not a string:", function () { function g() {} var r = []; [5, undefined, null, {}, Symbol("s")].forEach(function (v) { var b1 = g.bind(); Object.defineProperty(b1, "name", { value: v }); r.push(JSON.stringify(b1.bind().name), JSON.stringify(b1.bind().bind().name)); }); return r; });
show("a link's throwing name getter:", function () { function g() {} var b1 = g.bind(); Object.defineProperty(b1, "name", { get: function () { throw new RangeError("n"); } }); return b1.bind(); });
show("a link's length getter that renames the link:", function () { function g() {} var b1 = g.bind(); Object.defineProperty(b1, "length", { get: function () { Object.defineProperty(b1, "name", { value: "late" }); return 1; } }); return b1.bind().name; });
show("a name assigned:", function () { function g() {} var b = chainOf(g, 2); b.name = "x"; var strict = (function () { "use strict"; try { b.name = "x"; return "no throw"; } catch (e) { return e.constructor.name; } })(); return [b.name, strict]; });
show("a name made writable:", function () { function g() {} var b = chainOf(g, 2); Object.defineProperty(b, "name", { writable: true }); var before = b.name; b.name = "x"; return [before, b.name, b.bind().name]; });
show("names read at one site:", function () { function g() {} var fns = [g, Math.max, g.bind(), chainOf(g, 2), Math.max.bind(), parseInt, chainOf(Math.max, 3), function () {}]; var r = []; for (var round = 0; round < 3; round++) { for (var i = 0; i < fns.length; i++) r.push(fns[i].name); } return r.join("|"); });
show("lengths down a chain:", function () { function g(a, b, c, d, e) {} return [g.bind(null, 1).bind(null, 2).length, g.bind(null, 1).bind(null, 2, 3).bind().length, chainOf(g, 9).length, g.bind(null, 1, 2, 3).bind(null, 4, 5, 6).length]; });
show("names survive collection:", function () { var b = chainOf((function () { return function inner() {}; })(), 3); var o = {}; o["dyn" + "amic"] = function () {}; var c = chainOf(o.dynamic, 2); o = null; collect(); return [b.name, c.name]; });

// --- calls ---
function G() { return [this && this.t, Array.prototype.join.call(arguments)]; }
show("arguments in order, the innermost this:", function () { return G.bind({ t: 1 }, 1).bind({ t: 2 }, 2, 3).bind({ t: 3 }).bind(null, 4)(5, 6); });
show("no arguments at all:", function () { return chainOf(G.bind({ t: 1 }), 5)(); });
show("call, apply, Reflect.apply:", function () { var b = G.bind({ t: 1 }, 1).bind(null, 2).bind({ t: 3 }, 3); return [b.call({ t: 9 }, 4), b.apply({ t: 9 }, [4, 5]), Reflect.apply(b, { t: 9 }, [4, 5, 6])].join(" / "); });
show("spread through a chain:", function () { var many = []; for (var i = 0; i < 300; i++) many.push(i); function count() { return [arguments.length, arguments[0], arguments[1], arguments[301]]; } return count.bind(null, "a").bind(null, "b").bind()(...many); });
show("a builtin target:", function () { return [Math.max.bind(null, 1).bind(null, 5).bind()(3), Array.prototype.concat.bind([1]).bind(null, [2]).bind(null, [3])([4])]; });
show("a throw comes back up:", function () { function thrower(a) { throw new RangeError("t" + a); } try { thrower.bind(null, 1).bind().bind()(); } catch (e) { return [e.constructor.name, e.message]; } });
show("a generator and an async function:", function () { function* gen(a, b) { yield a; yield b; } var it = gen.bind(null, 1).bind(null, 2).bind()(); async function af(a) { return a; } return [it.next().value, it.next().value, af.bind(null, 1).bind().bind()() instanceof Promise]; });
show("an arrow keeps its this:", function () { var outer = { t: 7 }; var arrow = (function () { return (a, b) => [this.t, a, b]; }).call(outer); return arrow.bind({ t: 1 }, 1).bind({ t: 2 }, 2)(); });
show("a chain as a callback:", function () { function add(a, b) { return a + b; } var b = add.bind(null, 10).bind(); return [1, 2, 3].map(function (v) { return b(v); }); });
show("a chain rebound while it runs:", function () { var b; function target(n) { if (n > 0) { b = b.bind(); return b(n - 1) + 1; } return 0; } b = target.bind().bind(); return b(50); });

// --- construct ---
function F(a, b, c) { this.args = [a, b, c].join(); this.nt = new.target; }
show("construct down a chain:", function () { var B3 = F.bind({ x: 1 }, 1).bind({ y: 1 }, 2).bind({ z: 1 }); var x = new B3(3); return [x.args, x.nt === F, x instanceof F, x instanceof B3, Object.getPrototypeOf(x) === F.prototype, x.x, x.y, x.z]; });
show("the new target named by each link:", function () { var B1 = F.bind(null, 1), B2 = B1.bind(null, 2), B3 = B2.bind(null, 3); return [B3, B2, B1].map(function (nt) { var x = Reflect.construct(B3, [], nt); return [x.nt === F, Object.getPrototypeOf(x) === F.prototype, x.args].join(); }).join(" / "); });
show("a new target outside the chain:", function () { function N() {} var B3 = chainOf(F.bind(null, 1), 2); var x = Reflect.construct(B3, [2], N); var other = F.bind(); var y = Reflect.construct(B3, [], other); return [x.nt === N, Object.getPrototypeOf(x) === N.prototype, x.args, y.nt === other, y.args]; });
show("a new target above the link constructed:", function () { var B1 = F.bind(null, 1), B2 = B1.bind(null, 2), B3 = B2.bind(null, 3); var x = Reflect.construct(B2, [], B3); return [x.nt === B3, x instanceof F, x.args]; });
show("a class down a chain:", function () { class K { constructor(v, w) { this.v = v; this.w = w; this.nt = new.target; } } var BK = K.bind(null, 3).bind(null, 4).bind(); var k = new BK(); var called; try { BK(); called = "no throw"; } catch (e) { called = e.constructor.name; } return [k.v, k.w, k.nt === K, k instanceof K, k instanceof BK, called]; });
show("a derived class down a chain:", function () { class A { constructor() { this.nt = new.target; } } class K extends A {} var BK = chainOf(K, 3); var k = new BK(); return [k.nt === K, k instanceof A, Object.getPrototypeOf(BK) === A, Object.getPrototypeOf(BK.bind()) === A]; });
show("builtins constructed down a chain:", function () { return [new (Map.bind().bind())([[1, 2]]).get(1), new (Array.bind(null, 3).bind())().length, new (Date.bind(null, 2020).bind(null, 1))().getFullYear(), new (RangeError.bind(null, "m").bind().bind())().message, new (chainOf(RangeError, 3))("m") instanceof RangeError]; });
show("not constructors:", function () { var r = []; [(() => 1), Math.max, function* () {}, async function () {}, { m() {} }.m].forEach(function (f) { try { new (f.bind().bind())(); r.push("no throw"); } catch (e) { r.push(e.constructor.name); } }); return r; });
show("instanceof asks each link:", function () { var log = []; var B1 = F.bind(), B2 = B1.bind(), B3 = B2.bind(); var x = new F(); var plain = [x instanceof B3, {} instanceof B3]; Object.defineProperty(B2, Symbol.hasInstance, { value: function (v) { log.push("B2"); return v === 5; } }); return [plain, 5 instanceof B3, x instanceof B3, x instanceof B1, log]; });
show("collections inside construction down a chain:", function () {
  function Heavy(a, b, c) { collect(); this.a = a; this.b = b; this.c = c; this.list = [a, b, c]; collect(); }
  var B3 = Heavy.bind({ ignored: true }, { first: 1 }).bind(null, { second: 2 }).bind(null, { third: 3 });
  function N() {}
  var x = new B3(), y = Reflect.construct(B3, [], N);
  return [JSON.stringify(x), x instanceof B3, JSON.stringify(y), Object.getPrototypeOf(y) === N.prototype];
});

// --- long chains ---
show("a chain of 2,000 called:", function () { return chainOf(function () { return 1; }, 2000)(); });
show("a chain of 2,000 with an argument a link:", function () { var f = function () { var sum = 0; for (var i = 0; i < arguments.length; i++) sum += arguments[i] * (i + 1); return [arguments.length, arguments[0], arguments[1999], arguments[2000], sum]; }; for (var i = 0; i < 2000; i++) f = f.bind(null, i); return f(7); });
show("a chain of 100,000 called:", function () { var t = { t: "inner" }; return renamedChainOf(G.bind(t, 1), 100000)(2, 3); });
show("a chain of 100,000 constructed:", function () { var B = renamedChainOf(F.bind(null, 1), 100000); var x = new B(2, 3); function N() {} var y = Reflect.construct(B, [], N); return [x.args, x.nt === F, Object.getPrototypeOf(x) === F.prototype, y.nt === N, B.name, B.bind().name]; });
show("a chain of 100,000 that throws:", function () { function thrower() { throw new RangeError("deep"); } try { renamedChainOf(thrower, 100000)(); } catch (e) { return [e.constructor.name, e.message]; } });
show("and ordinary work after:", function () { function g(a, b) { return a + b; } return [g.bind(null, 1)(2), g.bind(null, 1).bind(null, 2)(), g.bind().name]; });
