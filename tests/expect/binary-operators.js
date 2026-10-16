// Binary operators on non-numbers: operands converted left then right,
// no right conversion after the left one throws, exponentiation's NaN
// cases, and the bitwise and shift operators against small literals.
var log = [];
function v(name, value) { return { valueOf: function () { log.push(name); return value; } }; }
var results = [v("a", 1) << v("b", 2), v("c", 8) >> v("d", 1), v("e", -8) >>> v("f", 28), v("g", 6) * v("h", 7), v("i", 7) / v("j", 2), v("k", 7) % v("l", 4), v("m", 2) ** v("n", 3), v("o", 5) - v("p", 3), v("q", 6) & v("r", 3), v("s", 6) | v("t", 1), v("u", 6) ^ v("w", 3)];
console.log("order: " + results.join(" ") + " " + log.join(""));

var bad = { valueOf: function () { throw new Error("left"); } };
var right = { valueOf: function () { log.push("R"); return 1; } };
var ops = {
  "-": function () { return bad - right; }, "*": function () { return bad * right; }, "/": function () { return bad / right; },
  "%": function () { return bad % right; }, "**": function () { return bad ** right; }, "|": function () { return bad | right; },
  "&": function () { return bad & right; }, "^": function () { return bad ^ right; }, "<<": function () { return bad << right; },
  ">>": function () { return bad >> right; }, ">>>": function () { return bad >>> right; }, "+": function () { return bad + right; },
  "<": function () { return bad < right; }, ">=": function () { return bad >= right; },
};
var out = [];
for (var k in ops) { log = []; try { ops[k](); out.push(k + ":no error"); } catch (e) { out.push(k + ":" + (log.length ? "right converted" : "stopped")); } }
console.log("left throws: " + out.join(" "));

console.log("exponent: " + [1 ** NaN, (-1) ** Infinity, (-1) ** -Infinity, 1 ** Infinity, "2" ** "3", 2 ** -1074, (-8) ** (1 / 3), 0 ** -1, (-0) ** -1, NaN ** 0, Math.pow(1, NaN), Math.pow(-1, Infinity), [2] ** [5]].join(" "));

var x = 1.9e10, y = -3.5, z = NaN;
console.log("small literals: " + [x | 0, y | 0, z | 0, x & 127, y & -1, x ^ 5, x << 3, y << -1, x >> 2, y >> 31, x >>> 1, y >>> 0, y >>> -127, "12" | 0, true << 4, null >>> 3, undefined & 1, (2 ** 31) | 0, -(2 ** 31) >> 0, 0xffffffff >>> 0, -1 >>> 0, 5 & -128, 7 ^ 127].join(" "));
