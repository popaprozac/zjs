// === and !== in a condition compare and branch in one instruction,
// against a register or an integer literal.
var out = [];
function t(label, v) { out.push(label + "=" + v); }
var vals = [0, -0, 1, 2.0, 2.5, NaN, "0", "a", null, undefined, true, 1000000, -8388608, {}];
for (var i = 0; i < vals.length; i++) {
  var v = vals[i];
  var r = "";
  if (v === 0) r += "z"; else r += "-";
  if (v !== 0) r += "n"; else r += "-";
  if (v === 2) r += "2"; else r += "-";
  if (v === 1000000) r += "M"; else r += "-";
  if (v === -8388608) r += "L"; else r += "-";
  if (v === 9000000) r += "X"; else r += "-";
  if (v === "0") r += "s"; else r += "-";
  if (v === null) r += "N"; else r += "-";
  if (v !== undefined) r += "d"; else r += "-";
  if (v === v) r += "="; else r += "!";
  t(i, r);
}
console.log(out.join(" "));

// At a loop's bottom, both ways.
var n = 0;
while (n !== 5) n++;
var list = { v: 1, next: { v: 2, next: { v: 3, next: null } } };
var sum = 0;
for (var p = list; p !== null; p = p.next) sum += p.v;
var k = 10;
do { k -= 2; } while (k === 8 || k !== 0);
var m = 3;
while (m === 3) m = 4;
console.log(n, sum, k, m);

// Operands with effects run once, in order.
var log = [];
function a() { log.push("a"); return 1; }
function b() { log.push("b"); return 1; }
if (a() === b()) log.push("same");
if (a() !== 1) log.push("wrong");
console.log(log.join(","));

// Allocating inside such a loop still collects.
var kept = null, count = 0;
for (var j = 0; j !== 100000; j++) { kept = { j: j, prev: kept && kept.j }; if (j % 1000 === 0) count++; }
console.log(count, kept.j, kept.prev);

// == and != in a condition: one instruction against a register, and one
// test of the other operand against null on either side; as values, the
// same answers.
var loose = [0, -0, 1, 2.0, 2.5, NaN, "0", "", "2", "a", null, undefined, true, false, {}, [], [2], { valueOf: function () { return 2; } }];
out = [];
for (var i = 0; i < loose.length; i++) {
  var v = loose[i], w = loose[(i + 1) % loose.length];
  var r = "";
  if (v == 0) r += "z"; else r += "-";
  if (v != 0) r += "n"; else r += "-";
  if (v == 2) r += "2"; else r += "-";
  if (v == "0") r += "s"; else r += "-";
  if (v == null) r += "N"; else r += "-";
  if (null == v) r += "M"; else r += "-";
  if (v != null) r += "d"; else r += "-";
  if (v != undefined) r += "u"; else r += "-";
  if (v == true) r += "T"; else r += "-";
  if (v == w) r += "w"; else r += "-";
  if (v == v) r += "="; else r += "!";
  r += ":" + (v == null ? 1 : 0) + (v != 0 ? 1 : 0) + (v == w ? 1 : 0) + (undefined == v ? 1 : 0);
  r += ":" + [v == null, v != 0, v == w, v != w, null != v].map(Number).join("");
  t(i, r);
}
console.log(out.join(" "));

// A Symbol equals itself, and the object wrapping it, and nothing else.
var sym = Symbol("s"), boxed = Object(sym);
console.log([sym == sym, sym != sym, sym == boxed, boxed == sym, sym == Symbol("s"), sym == "s", sym == null].map(Number).join(""));

// At a loop's bottom, both ways, against null and against a value.
var q = list, nodes = 0;
while (q != null) { nodes++; q = q.next; }
var walked = 0;
for (var p = list; null != p; p = p.next) walked += p.v;
var tries = 0, found = null;
do { tries++; if (tries == 3) found = tries; } while (found == null);
var x = 0;
while (x != 5) x++;
var y = "3", steps = 0;
do { steps++; } while (steps != y);
console.log(nodes, walked, tries, x, steps);

// Operands with effects run once, in order; a conversion runs once, and
// one that throws is caught, in a branch and at a loop's bottom.
log = [];
var counted = { valueOf: function () { log.push("valueOf"); return 2; } };
if (a() == b()) log.push("same");
if (counted == 2) log.push("two");
if (2 != counted) log.push("wrong");
var thrower = { valueOf: function () { throw new Error("boom"); } };
try { if (thrower == 1) log.push("taken"); log.push("after"); } catch (e) { log.push("caught " + e.message); }
try { var spins = 0; do { spins++; } while (thrower != 1); } catch (e) { log.push("caught " + e.message + " " + spins); }
console.log(log.join(","));

// Allocating inside such a loop still collects.
var chain = null;
for (var j = 0; j < 100000; j++) chain = { next: chain, j: j };
var length = 0, last = null;
for (var c = chain; c != null; c = c.next) { length++; last = { at: c.j }; }
console.log(length, last.at);
