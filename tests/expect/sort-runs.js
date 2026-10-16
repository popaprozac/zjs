// Array.prototype.sort merges halves that are already in order with one
// comparison, and stays stable.
function check(label, arr, cmp) {
  var calls = 0;
  var sorted = arr.slice().sort(function (a, b) { calls++; return cmp ? cmp(a, b) : a - b; });
  var ok = true;
  for (var i = 1; i < sorted.length; i++) if ((cmp ? cmp(sorted[i - 1], sorted[i]) : sorted[i - 1] - sorted[i]) > 0) ok = false;
  console.log(label, arr.length, ok, calls <= arr.length * 20);
}
var sizes = [0, 1, 2, 7, 8, 9, 15, 16, 17, 100, 1000];
for (var s = 0; s < sizes.length; s++) {
  var n = sizes[s], asc = [], desc = [], saw = [], rnd = [];
  for (var i = 0; i < n; i++) { asc.push(i); desc.push(n - i); saw.push(i % 5); rnd.push((i * 7919) % 101); }
  check("asc", asc); check("desc", desc); check("saw", saw); check("rnd", rnd);
}
// Comparisons on sorted input: linear-ish, not n log n.
var many = []; for (var i = 0; i < 4096; i++) many.push(i);
var count = 0;
many.sort(function (a, b) { count++; return a - b; });
console.log("sorted 4096 compares under 6000:", count < 6000);

// Stability: equal keys keep their order.
var recs = [];
for (var i = 0; i < 200; i++) recs.push({ k: i % 3, i: i });
recs.sort(function (a, b) { return a.k - b.k; });
var stable = true;
for (var i = 1; i < recs.length; i++) if (recs[i - 1].k === recs[i].k && recs[i - 1].i > recs[i].i) stable = false;
console.log("stable", stable, recs[0].i, recs[199].i);

// Holes, undefined, default string order, odd comparator results.
var holes = [3, , 1, undefined, 2, , undefined];
holes.sort();
console.log(JSON.stringify(holes), holes.length, 1 in holes, 5 in holes);
console.log([10, 9, 1, 100, 25].sort().join(","));
console.log([3, 1, 2].sort(function () { return NaN; }).join(","));
console.log([3, 1, 2].sort(function (a, b) { return String(a - b); }).join(","));
console.log([5, 4, 3, 2, 1, 0, 9, 8, 7, 6].toSorted(function (a, b) { return a - b; }).join(","));

// A throwing comparator leaves the array as it was.
var arr = [5, 3, 9, 1, 7, 2, 8, 6, 4, 0, 11, 10];
var seen = 0;
try { arr.sort(function (a, b) { if (++seen > 12) throw new Error("stop"); return a - b; }); } catch (e) { console.log(e.message); }
console.log(arr.join(","));
