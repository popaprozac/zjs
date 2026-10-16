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
