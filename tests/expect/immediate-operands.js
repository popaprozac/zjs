// Integer literals in [-32768, 32767] ride in the instruction as the
// right operand of arithmetic, comparison, and bitwise operators.
function show(label) {
  var parts = [label];
  for (var i = 1; i < arguments.length; i++) parts.push(Object.is(arguments[i], -0) ? "-0" : String(arguments[i]));
  console.log(parts.join(" "));
}
var x = 1234, z = 0, n = -7, s = "21";
show("mul", x * 7919);
show("mod", (x * 7919 + 3) % 10007);
show("edges", x + 32767, x - 32768, x * -32768, x + 32768, x - -32768);
show("negzero mul", z * -3);
show("negzero mod", -4 % 2);
show("neg mod", n % 3, n % -3, 7 % -3);
show("mod zero", x % 0);
show("mul overflow", 65535 * 32767 * 3);
show("strings", s * 2, s % 4, s + 1, s - 1);
var calls = 0;
var obj = { valueOf: function () { calls++; return 6; } };
show("valueOf", obj * 300, obj % 4, calls);
show("bitwise", x | 40000, x & -32768, x ^ 32767, x | 255);
show("shifts", x << 300, x >> 33, -x >>> 1000, x << -1);
show("compare", x < 32767, x >= -32768, x > 1233);
var c = 5; c *= 3; c %= 4; c += 1000; c -= 20000;
show("compound", c);
try { Symbol() * 2; } catch (e) { show("symbol", e.constructor.name); }
var sum = 0;
for (var i = 0; i < 1000; i++) sum = (sum + (i * 31) % 97) | 0;
show("loop", sum);
