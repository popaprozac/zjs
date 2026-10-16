// String concat in a loop. O(n²) work in our current concat
// implementation — useful for measuring allocator + string copy
// throughput rather than absolute speed.
let s = "";
let n = 2000;
for (let i = 0; i < n; i = i + 1) {
  s = s + "x";
}
s.length
