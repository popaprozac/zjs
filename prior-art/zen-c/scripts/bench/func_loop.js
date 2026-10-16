// Hot numeric FUNCTION called repeatedly — the workload class the copy-and-patch
// JIT actually covers (pure register arithmetic + loop, single return, no calls
// / property / global access inside the body). Exercises the J5 hot-function
// dispatch + J6 OSR deopt-resume.
//
// Contrast with int_loop / sieve, whose hot loops live at TOP LEVEL: top-level
// `let` compiles to globals, so those stay interpreted in both builds. Here the
// arithmetic is inside `sumTo`, which goes hot and JITs. The outer driver loop
// is interpreted; the time is dominated by the JIT'd body.
function sumTo(n) {
  let s = 0;
  for (let i = 0; i < n; i = i + 1) {
    s = s + i;
  }
  return s;
}

let total = 0;
for (let k = 0; k < 120; k = k + 1) {
  total = total + sumTo(500000);   // 6e7 inner iterations across 120 hot calls
}
total
