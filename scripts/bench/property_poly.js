// Polymorphic property access — alternating shapes. Without the
// megamorphic fallback this would thrash; with it, the site flips
// to slow-path-only after IC_MEGAMORPHIC_LIMIT misses and stops
// re-patching.
let oA = { x: 1 };
let oB = { y: 2, x: 3 };
let oC = { a: 4, b: 5, x: 6 };
let n = 200000;
let s = 0;
for (let i = 0; i < n; i = i + 1) {
  let pick = (i % 3 === 0) ? oA : ((i % 3 === 1) ? oB : oC);
  s = s + pick.x;
}
s
