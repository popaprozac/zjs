// `(a + b) | 0` is one instruction: the sum truncated to 32 bits, with
// what `+` and `| 0` do on other values unchanged.
var total = 0;
for (var i = 0; i < 1000; i++) total = (total + i * 1000003) | 0;
console.log(total, (2147483647 + 1) | 0, (-2147483648 + -1) | 0, (1.9 + 1.2) | 0, (-1.5 + 0) | 0);
console.log(("5" + 1) | 0, ("x" + 1) | 0, (true + true) | 0, (null + undefined) | 0, ([] + 4) | 0);
var calls = [];
var left = { valueOf: function () { calls.push("left"); return 2.5; } };
var right = { valueOf: function () { calls.push("right"); return 4; } };
console.log((left + right) | 0, calls.join());
console.log((1e10 + 1) | 0, (4294967296 + 5) | 0, (NaN + 1) | 0, (Infinity + 1) | 0);
var a = 3, b = 4;
var c = (a + b) | 0, d = ((a + b)) | 0, e = (a + b + a) | 0;
console.log(c, d, e);
try { (Symbol() + 1) | 0; } catch (err) { console.log(err instanceof TypeError); }
var h = 0;
var word = "hash me";
for (var k = 0; k < word.length; k++) h = (h * 31 + word.charCodeAt(k)) | 0;
console.log(h);
