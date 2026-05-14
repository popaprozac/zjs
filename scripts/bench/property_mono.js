// Monomorphic property access — the IC should patch once and hit
// the fast slot read every subsequent iteration. Measures LoadProp's
// fast path plus its surrounding dispatch.
let o = { x: 0 };
let n = 500000;
let sum = 0;
for (let i = 0; i < n; i = i + 1) {
  o.x = i;
  sum = sum + o.x;
}
sum
