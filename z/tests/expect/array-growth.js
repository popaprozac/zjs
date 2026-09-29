// Arrays grow in place while their slots are the last thing allocated,
// and move when something was allocated after them; either way the
// elements, holes, and length stay what they were.
var a = [];
for (var i = 0; i < 5000; i++) a.push(i * 3);
console.log(a.length, a[0], a[4999], a.indexOf(2997));

// Two arrays growing in turn: each growth finds the other on top.
var b = [], c = [];
for (var j = 0; j < 3000; j++) { b.push(j); c.push("c" + j); }
console.log(b.length, c.length, b[2999], c[2999], b[1234] + c[1234]);

// Growth with objects allocated between the pushes, kept and dropped.
var kept = [], log = [];
for (var k = 0; k < 4000; k++) {
  log.push({ k: k, tag: "t" + (k % 7) });
  if (k % 3 === 0) kept.push([k, k + 1]);
}
console.log(log.length, kept.length, log[3999].tag, kept[1333][1]);

// A write past the end leaves holes, then the array grows again.
var holes = [1, 2];
holes[40] = "x";
console.log(holes.length, 5 in holes, holes[40], holes.filter(function () { return true; }).length);
for (var h = 0; h < 100; h++) holes.push(h);
console.log(holes.length, holes[141], 20 in holes, holes.join("").length);

// Nested growth: an array of arrays, each grown after the others.
var rows = [];
for (var r = 0; r < 50; r++) rows.push([]);
for (var round = 0; round < 60; round++) {
  for (var q = 0; q < 50; q++) rows[q].push(q * round);
}
var sum = 0;
for (var q2 = 0; q2 < 50; q2++) sum += rows[q2].length + rows[q2][59];
console.log(sum, rows[49][59], rows[0].length);

// Survivors of many collections keep their elements.
var survivors = [];
for (var s = 0; s < 200; s++) {
  var tmp = [];
  for (var t = 0; t < 200; t++) tmp.push({ v: t });
  if (s % 20 === 0) survivors.push(tmp);
}
var check = 0;
for (var u = 0; u < survivors.length; u++) check += survivors[u].length + survivors[u][199].v;
console.log(survivors.length, check);
