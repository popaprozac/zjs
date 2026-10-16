// Loops test their condition at the bottom, entered by a jump: the
// order of tests, bodies, updates, continue, and break is unchanged.
var log = [];
function note(x) { log.push(x); return x; }

// while: the test runs before each body and once more at the end.
var i = 0;
while (note("t" + i) && i < 3) { note("b" + i); i++; }
console.log(log.join(" "));

// for: init, test, body, update, test...; continue goes to the update.
log = [];
for (var j = note(0); note(j < 4); j = note(j + 1)) {
  if (j === 1) continue;
  if (j === 3) break;
  note("body" + j);
}
console.log(log.join(" "));

// A fused comparison at the bottom, against a literal and a register,
// with NaN, strings, and a valueOf that counts its calls.
var n = 0;
for (var k = 0; k < 5; k++) n += k;
console.log(n);
var m = 0, limit = 7;
for (var k2 = 10; k2 >= limit; k2--) m += k2;
console.log(m);
var nanRuns = 0;
for (var x = NaN; x < 10; x++) nanRuns++;
console.log(nanRuns);
var s = "a", steps = 0;
while (s <= "aaaa") { s += "a"; steps++; }
console.log(steps, s);
var calls = 0;
var bound = { valueOf: function () { calls++; return 3; } };
for (var v = 0; v < bound; v++) {}
console.log(calls);
var big = 0;
for (var w = 0; w < 100000; w += 25000) big++;
console.log(big);

// A condition that is not a comparison, and one that is false at once.
var list = [3, 2, 1], popped = [];
while (list.length) popped.push(list.pop());
console.log(popped.join(","));
var never = 0;
while (false) never++;
for (var z = 5; z < 5; z++) never++;
console.log(never);

// for (;;) and a labeled continue to the outer loop.
var count = 0;
for (;;) { if (++count > 4) break; }
console.log(count);
var pairs = [];
outer: for (var a = 0; a < 3; a++) {
  for (var b = 0; b < 3; b++) {
    if (b > a) continue outer;
    pairs.push("" + a + b);
  }
}
console.log(pairs.join(" "));

// Closures over a let head see one binding per iteration, with continue.
var fns = [];
for (let q = 0; q < 4; q++) {
  if (q === 2) continue;
  fns.push(function () { return q; });
}
console.log(fns.map(function (f) { return f(); }).join(","));

// A generator yielding in the condition resumes into the test.
function* gen() {
  var r = 0;
  while ((yield r) !== "stop") r++;
  return "done " + r;
}
var it = gen();
console.log(it.next().value, it.next().value, it.next().value, it.next("stop").value);

// do-while keeps its shape; a loop allocating without calls still runs.
var d = 0;
do { d++; } while (d < 3);
console.log(d);
var kept = null;
for (var e = 0; e < 200000; e++) kept = { e: e, next: kept && kept.e };
console.log(kept.e, kept.next);
