// super(...) hands its arguments to the parent as they were written:
// none, a few, many, or a spread, to a class, a function, a builtin, a
// binding, and a parent changed at run time. The derived constructor's
// own registers, read after super() returns, are its own.
var r = [];
function t(label, f) { try { r.push(label + ": " + String(f())); } catch (e) { r.push(label + ": " + e.constructor.name); } }
function collect() { if (typeof gc === "function") gc(); }
class Args { constructor(...given) { this.given = given.length + ":" + given.join("|"); } }
class Plain { constructor(a, b = "dflt", c) { this.got = [a, b, c, arguments.length].join("|"); } }
function Old(a, b) { this.got = [a, b, arguments.length, new.target === undefined].join("|"); }

t("none", function () { class D extends Args { constructor() { super(); } } return new D().given; });
t("one", function () { class D extends Args { constructor(x) { super(x); } } return new D(7).given; });
t("three, a default left out", function () { class D extends Plain { constructor() { super(1, undefined, 3); } } return new D().got; });
t("many", function () { class D extends Args { constructor() { super(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19); } } return new D().given; });
t("spread", function () { class D extends Args { constructor(...xs) { super(...xs, "end"); } } return new D("a", "b").given; });
t("spread of nothing", function () { class D extends Args { constructor() { super(...[]); } } return new D().given; });
t("spread with holes", function () { class D extends Plain { constructor() { super(...[1, , 3]); } } return new D().got; });
t("the implicit constructor", function () { class D extends Plain {} return new D("x", "y", "z").got; });
t("a function parent", function () { class D extends Old { constructor() { super("p", "q"); } } var d = new D(); return d.got + "|" + (d instanceof D); });
t("argument order", function () { var order = []; function v(n) { order.push(n); return n; } class D extends Args { constructor() { super(v(1), v(2), v(3)); } } return new D().given + " " + order.join(); });
t("locals after super", function () { class D extends Args { constructor(a, b) { var c = a + b, d = c * 2, e = [a, b]; super(e, d); this.mine = [a, b, c, d, e.length].join(); } } var o = new D(2, 3); return o.mine + " " + o.given; });
t("three levels", function () { class M extends Plain { constructor(a, b) { super(b, a); } } class D extends M { constructor(...xs) { super(...xs); } } return new D("first", "second").got; });
t("a collection in the parent", function () { class P { constructor(a, b) { collect(); this.got = a.list.join() + b.word; } } class D extends P { constructor() { super({ list: [1, 2] }, { word: "!" }); } } return new D().got; });
t("Array", function () { class D extends Array { constructor() { super(1, 2, 3); } } var d = new D(); return d.length + ":" + d.join() + ":" + (d instanceof D); });
t("Array spread", function () { class D extends Array { constructor(...xs) { super(...xs); } } var d = new D(4); return d.length + ":" + (d instanceof D); });
t("Map", function () { class D extends Map { constructor(entries) { super(entries); } } return new D([["k", "v"]]).get("k"); });
t("Error", function () { class D extends Error { constructor(m) { super(m, { cause: "c" }); } } var e = new D("msg"); return e.message + ":" + e.cause + ":" + (e instanceof D); });
t("a binding", function () { var B = Old.bind(null, "bound"); B.prototype = Old.prototype; class D extends B { constructor() { super("late"); } } return new D().got; });
t("re-parented between constructs", function () { class A { constructor(x) { this.from = "A" + x; } } class B { constructor(x) { this.from = "B" + x; } } class D extends A { constructor(x) { super(x); } } var first = new D(1).from; Object.setPrototypeOf(D, B); return first + "," + new D(2).from; });
t("re-parented to a builtin", function () { class D extends Object { constructor() { super(); } } Object.setPrototypeOf(D, Array); var d = new D(); return Array.isArray(d) + ":" + d.length; });
t("Reflect.construct with another new target", function () { class D extends Plain { constructor(a) { super(a, "two"); } } function NT() {} var o = Reflect.construct(D, ["one"], NT); return o.got + ":" + (Object.getPrototypeOf(o) === NT.prototype); });
t("a parent that throws", function () { class P { constructor(a) { throw new TypeError(a); } } class D extends P { constructor() { try { super("thrown"); } catch (e) { return { m: e.message }; } } } return new D().m; });
t("a second super with arguments", function () { var runs = []; class P { constructor(a) { runs.push(a); } } class D extends P { constructor() { super(1); try { super(2); } catch (e) { runs.push(e.constructor.name); } } } new D(); return runs.join(); });
t("not a constructor", function () { class D extends Object { constructor() { super(1, 2); } } Object.setPrototypeOf(D, Math.max); new D(); });
t("a second super() many times over", function () { var seen = {}; class P { constructor() {} } class D extends P { constructor() { super(); for (var i = 0; i < 60000; i++) { try { super(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19); } catch (e) { seen[e.constructor.name] = (seen[e.constructor.name] || 0) + 1; } } } } new D(); return JSON.stringify(seen); });
t("in a deep recursion", function () { class D extends Args { constructor(n) { super(n); } } function down(n) { return n == 0 ? new D("bottom").given : down(n - 1); } return down(500); });
t("a spread too long", function () { class D extends Args { constructor(xs) { super(...xs); } } new D(new Array(2000000).fill(0)); });
console.log(r.join("\n"));
