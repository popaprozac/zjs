// Operands the compiler folds into instructions or reads in place:
// compound assignment into locals (read before the right side runs,
// unless the right side assigns first), relational branches against
// literals across the whole 24-bit range and past it, and negated
// literals folded to constants.
var out = [];
function compound() {
  var x = 10, log = [];
  function bump() { x = 100; return 1; }
  x += bump(); log.push(x);
  var y = 5; y -= -3; y *= 2; y |= 1; y <<= 2; y >>= 1; y >>>= 0; y **= 2; y %= 7; y /= 2; y ^= 3; y &= 7; log.push(y);
  var s = "a"; s += "b" + s; s += 1; log.push(s);
  var z = 1; var w = (z += 1) + (z += 2); log.push(z, w);
  var o = { valueOf: function () { log.push("valueOf"); return 4; } };
  var t = 2; t *= o; log.push(t);
  return log.join(",");
}
out.push(compound());
var probes = [-8388609, -8388608, -8388607, -40000, -32769, -32768, -129, -128, -1, 0, 1, 127, 128, 255, 256, 32767, 32768, 65535, 65536, 300000, 8388607, 8388608, 1.5, "300000", "x", null, undefined, NaN, -0, 1e30];
function test(v) {
  var r = "";
  if (v < -8388608) r += "a"; if (v <= -8388608) r += "b"; if (v > -8388608) r += "c"; if (v >= -8388608) r += "d";
  if (v < 8388607) r += "e"; if (v <= 8388607) r += "f"; if (v > 8388607) r += "g"; if (v >= 8388607) r += "h";
  if (v < 300000) r += "i"; if (v <= -32768) r += "j"; if (v > 32767) r += "k"; if (v >= 128) r += "l";
  if (v < -129) r += "m"; if (v > 65535) r += "n"; if (v <= 0) r += "o"; if (v >= -40000) r += "p";
  if (v < 8388608) r += "q"; if (v > -8388609) r += "r";
  return r;
}
for (var i = 0; i < probes.length; i++) out.push(String(probes[i]) + ":" + test(probes[i]));
var count = 0; for (var k = 0; k < 300000; k++) count++; out.push(count);
var down = 0; for (var d = 10; d >= -300000; d -= 1000) down++; out.push(down);
out.push([Object.is(-0, -(0)), 1 / -0, - -1, -(1e400), -(0x10), -(-(0)), 1 / -(-0), -2147483648, -2147483649, - - -3.5, (-5) + 1, 3 - -2, typeof -1].map(String).join(" "));
console.log(out.join("\n"));
// A return of a conditional branches to a return in each arm, nested
// alike; a fused test in a conditional expression; names inferred for
// functions after an initializer read in place; compound assignment to a
// captured binding with a right side that has effects.
function classify(n) { return n < 0 ? "negative" : n === 0 ? "zero" : (n < 10 ? "small" : "large"); }
out = [classify(-3), classify(0), classify(4), classify(40), (function (x) { return x > 2 ? x * 2 : x; })(5)];
out.push([1, 5, 9].map(function (v) { return v < 5 ? "lo" : v <= 5 ? "mid" : "hi"; }).join(""));
function namer(start) { var n = start; var f = function () {}; return [f.name, (function () {}).name, (() => 0).name]; }
out.push(namer(1).join("|"));
function capture(start) { let total = start; const add = (step) => { total += step; return total; }; add(2); let calls = 0; total += (calls++, 5); return total + ":" + calls; }
out.push(capture(1));
console.log(out.join(","));
