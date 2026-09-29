// A counted loop steps its counter and tests it in one instruction at
// the bottom, after one test ahead of the loop; everything `++` and `<`
// do on other values happens as before.
var log = [];
function note(x) { log.push(x); return x; }

var s = 0;
for (var i = 0; i < 5; i++) s += i;
var never = 0;
for (var z = 10; z < 5; z++) never++;
for (var n = 0; n < 0; ++n) never++;
console.log(s, i, never, z, n);

// A register bound, changed by the body; a const bound; a let counter.
var bound = 3, visits = 0;
for (var j = 0; j < bound; j++) { visits++; if (j === 1) bound = 6; }
const limit = 4;
var viaConst = [];
for (let k = 0; k < limit; k++) viaConst.push(k);
console.log(visits, j, viaConst.join());

// continue, break, and nested loops with labels.
var picked = [];
outer: for (var a = 0; a < 4; a++) {
  for (var b = 0; b < 4; ++b) {
    if (b === 1) continue;
    if (b > a) continue outer;
    if (a === 3 && b === 2) break outer;
    picked.push("" + a + b);
  }
}
console.log(picked.join(" "), a, b);

// Counters that are not small integers.
var d = 0.5, dSteps = 0;
for (; d < 3; d++) dSteps++;
var str = "1", sSteps = 0;
for (var t = str; t < 4; t++) sSteps++;
var big = 2147483645, bigSteps = 0;
for (var w = big; w < 2147483649; w++) bigSteps++;
console.log(d, dSteps, sSteps, typeof t, t, bigSteps, w);
var calls = 0;
var counterObj = { valueOf: function () { calls++; return 7; } };
var o = counterObj, oSteps = 0;
for (; o < 10; o++) oSteps++;
console.log(o, oSteps, calls);

// A bound whose valueOf runs at every test, and NaN.
var tests = 0;
var fancy = { valueOf: function () { tests++; return 3; } };
for (var f = 0; f < fancy; f++) {}
var nanSteps = 0;
for (var q = 0; q < NaN; q++) nanSteps++;
console.log(f, tests, nanSteps);

// A counter reassigned in the body.
var reset = 0, laps = 0;
for (var r = 0; r < 5; r++) { laps++; if (r === 3 && reset === 0) { reset = 1; r = "1"; } }
console.log(laps, r);

// Throws from the test propagate; generators resume into the loop.
var bad = { valueOf: function () { throw new Error("no"); } };
try { for (var e = 0; e < bad; e++) {} } catch (err) { console.log("caught", err.message, e); }
function* gen() { for (var g = 0; g < 3; g++) yield g * 2; }
console.log([...gen()].join());
var many = 0;
for (var m = 0; m < 300000; m++) { if (m % 1000 === 0) note(m); many = (many + m) | 0; }
console.log(many, log.length, log[log.length - 1]);

// A bound that is a binding's `length`: arrays (growing as the loop
// runs), strings, array-likes, a getter read at every test, and nothing.
var arr = [1, 2, 3], total = 0;
for (var x = 0; x < arr.length; x++) { total += arr[x]; if (x === 1) arr.push(10); }
var text = "héllo", codes = 0;
for (var y = 0; y < text.length; y++) codes += text.charCodeAt(y);
var like = { length: 3 }, likeSteps = 0;
for (var u = 0; u < like.length; u++) likeSteps++;
var reads = 0;
var getterLike = { get length() { reads++; return 2; } };
for (var v = 0; v < getterLike.length; v++) {}
console.log(total, x, codes, likeSteps, v, reads);
var missing;
try { for (var mm = 0; mm < missing.length; mm++) {} } catch (err2) { console.log(err2 instanceof TypeError, mm); }
var shrinking = [1, 2, 3, 4, 5, 6], seen = [];
for (var sh = 0; sh < shrinking.length; sh++) { seen.push(shrinking[sh]); shrinking.pop(); }
console.log(seen.join(), sh);
