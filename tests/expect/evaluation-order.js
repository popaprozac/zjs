// Operands read in place, results written in place, immediates, fused
// branches, and steps in place keep the language's evaluation order.
function t1(a) { return a + (a = 5); }
function t2(a) { var b = a; b = b + (b = 3) + b; return b; }
function t3(o) { var p = o; return p.x + (p = { x: 100 }).x + p.x; }
function t4(a, i) { return a[i] + a[i = 1] + i; }
function t5(x) { x = x + 1; x = x * 2; var y = x; y = y - x; return [x, y]; }
function t6(n) { var s = 0; for (var i = 0; i < n; i++) { s = s + i; } return s; }
function t7(x) { var r = (x = 2) + x; return [r, x]; }
function t8(a) { let b = a + 1; const c = b * 2; b = c + b; return [b, c]; }
function t9(a) { try { return a; } finally { a = 99; } }
function t10(a) { var f = function () { return a; }; a = a + 1; return f(); }
function t11(s) { s = s + "x"; s = s + s; return s; }
function t12(a) { return (a = a + 1) + (a = a + 1) + a; }
console.log([t1(1), t2(2), t3({ x: 1 }), t4([10, 20], 0), t5(3).join(","), t6(10), t7(1).join(","), t8(1).join(","), t9(7), t10(1), t11("a"), t12(1)].join(" | "));
function u1(x) { var a = x++; var b = ++x; var c = x--; var d = --x; return [a, b, c, d, x].join(","); }
function u2(s) { var t = s; t++; return [t, typeof t].join(","); }
function u3(o) { var v = o; v++; return v; }
function u4(n) { var r = []; for (var i = 0; i < n; ++i) r.push(i + 1, i - 1, i < 2, i <= 2, i > 2, i >= 2); return r.join(""); }
function u5(x) { return [x + 1, x - 1, x < 1, x > 1].join(","); }
console.log([u1(5), u2("41"), u3({ valueOf: function () { return 9; } }), u4(3), u5("7"), u5(null), u5(undefined), u5({ valueOf: function () { return 1; } })].join(" | "));
function c1(x) { x = x > 1 ? x - 1 : x + 10; return x; }
function c2(f, a) { var r; r = f(a, a + 1); return r; }
function c3(o) { var r; r = o.m(1, 2); return r + o.m(r, 0); }
function c4(x) { var y = x ? (x = 0) : x; return [x, y].join(","); }
function c5(f) { var a = 1; a = f(a, (a = 5), a); return a; }
console.log([c1(5), c1(0), c2(function (p, q) { return p * q; }, 3), c3({ m: function (p, q) { return p + q + 1; } }), c4(4), c5(function (p, q, r) { return [p, q, r].join("/"); })].join(" | "));
function b1(a, b) { var r = []; if (a < b) r.push("lt"); if (a <= b) r.push("le"); if (a > b) r.push("gt"); if (a >= b) r.push("ge"); if (a < 3) r.push("lt3"); if (a >= 3) r.push("ge3"); return r.join(""); }
function b2(n) { var i = 0, s = 0; while (i < n) { s += i; i++; } for (var j = 10; j > 0; j--) s += j; return s; }
var order = [];
var lhs = { valueOf: function () { order.push("l"); return 1; } }, rhs = { valueOf: function () { order.push("r"); return 2; } };
function b3() { if (lhs < rhs) order.push("t"); if (lhs > rhs) order.push("T"); return order.join(""); }
console.log([b1(1, 2), b1(2, 2), b1(3, 2), b1(NaN, 2), b1("10", "9"), b1("10", 9), b1(undefined, 1), b2(5), b3()].join(" | "));

// A parenthesized target is assigned, updated, and iterated into as the
// bare one is; it names no function, and a literal in parentheses is no
// pattern.
function p1(a) { (a) = a + 1; ((a)) += 2; (a)++; ++(a); (a) *= (a = 2) + 1; return a; }
function p2(o) { (o.x) = 1; (o["y"]) = 2; (o.x) += 10; (o.y)--; return [o.x, o.y, (o.x)++, ++(o["y"]), o.x, o.y].join(); }
function p3() { var n = 0; var read = function () { return n; }; (n) = 5; (n) += 1; (n)++; return read(); }
var pg = 1; (pg) = 2; (pg) **= 3;
function p4() { var k, v, async, o = {}; for ((k) in { a: 1 }); for ((v) of [7]); for ((async) of [8]); for ((o.last) of [8, 9]); return [k, v, async, o.last].join(); }
function p5() { var f, g, c, h, getH = () => h; (f) = function () {}; g = function () {}; (c) = class {}; (h) = () => 0; return [JSON.stringify(f.name), g.name, JSON.stringify(c.name), JSON.stringify(getH().name)].join(); }
function p6(a) { var log = []; (a) ||= 4; log.push(a); (a) &&= 5; log.push(a); a = null; (a) ??= 6; log.push(a); return log.join(); }
function p7() { var s = { w: 1 }; with (s) { (w) = 2; (w) += 3; (w)++; } return s.w; }
function p8(a) { var b = a; return [a + ((a) = 5) + a, b + (b)++ + b, b + ++(b)].join(); }
class P { #v = 1; m() { (this.#v) = 5; (this.#v)++; return this.#v; } }
console.log([p1(1), p2({}), p3(), pg, p4(), p5(), p6(0), p7(), p8(1), new P().m()].join(" | "));
function rejects(src) { try { Function(src); return "parsed"; } catch (e) { return e.name; } }
console.log(["(a) = 1", "((a)) += 1", "(a)++", "++(a)", "for ((a) of []);", "([a]) = [1]", "({a}) = {}", "[([a])] = [[1]]",
  "(a, b) = 1", "(a = 1) = 2", "for (([a]) of []);", "'use strict'; (eval) = 1"].map(rejects).join(" "));

// A named property updated in place (`o.n++`, `o.n += v`) reads and
// writes as `o.n` and `o.n = v` do: the getter once, then the operand,
// then the setter; the step converts as `x++` does; one site sees
// objects of several shapes, inherited and frozen properties, arrays,
// primitives, and a right side that rebinds the object.
function m1() { var o = { n: 5, s: "41", u: undefined, b: { valueOf: function () { return 9; } } }; var r = [o.n++, o.n, ++o.n, o.n--, --o.n, o.n]; o.s++; o.u++; o.b--; o.n += 10; o.n -= 1; o.n *= 2; o.s += "x"; var t = { s: "7" }; var old = t.s++; r.push(o.s, typeof o.u, o.u, o.b, o.n, typeof old, old, t.s); return r.join(","); }
function m2() { var log = []; var o = { get v() { log.push("get"); return 5; }, set v(x) { log.push("set " + x); } }; var f = function () { log.push("f"); return 2; };
  log.push(o.v++); log.push(++o.v); o.v--; o.v += f(); o.v **= f(); return log.join(" "); }
function m3() { var log = []; var proto = { set v(x) { log.push("proto set " + x); } }; var child = Object.create(proto); child.v++; var c2 = Object.create({ n: 4 }); c2.n++; return log.concat([Object.keys(child).length, c2.n, Object.getPrototypeOf(c2).n, Object.keys(c2).join()]).join(" "); }
function m4() { var f = Object.freeze({ n: 1 }); var a = f.n++, b = ++f.n; f.n += 5; var strict = (function () { "use strict"; try { f.n++; return "no"; } catch (e) { return e.name; } })(); var strict2 = (function () { "use strict"; try { f.n -= 1; return "no"; } catch (e) { return e.name; } })(); return [a, b, f.n, strict, strict2].join(","); }
function m5() { var objs = [{ n: 1 }, { a: 0, n: 2 }, { b: 0, c: 0, n: 3 }, Object.create({ n: 4 }), { n: 5, x: 1, y: 2, z: 3, w: 4 }]; delete objs[4].x; var r = [];
  for (var k = 0; k < 3; k++) for (var i = 0; i < objs.length; i++) { objs[i].n++; objs[i].n += 10; r.push(objs[i].n); } return r.join(","); }
function m6() { var o = { n: 1 }, keep = o; o.n += (o = { n: 100 }, 1); var p = { n: 1 }, pk = p; p.n++; return [keep.n, o.n, pk.n].join(","); }
class Counter { constructor() { this.count = 0; this.total = 0; } tick(v) { this.count++; this.total += v; return this; } }
function m7() { var c = new Counter(); for (var i = 0; i < 100; i++) c.tick(i); return [c.count, c.total].join(","); }
function m8() { var a = [1, 2, 3]; a.length--; var l1 = a.length; a.length += 2; var s = "abc"; var sl = s.length++; var z = null, e1; try { z.n++; } catch (e) { e1 = e.name; } var e2; try { z.n += 1; } catch (e) { e2 = e.name; } return [l1, a.length, a.join("/"), sl, s.length, e1, e2].join(","); }
console.log([m1(), m2(), m3(), m4(), m5(), m6(), m7(), m8()].join(" | "));
