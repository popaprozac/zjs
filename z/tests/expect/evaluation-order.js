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
