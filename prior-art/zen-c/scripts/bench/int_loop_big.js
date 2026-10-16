// 10× the iterations of int_loop. Long enough that JITs (node/bun)
// should amortize compile cost and dominate; we and qjs scale
// linearly because we're always interpreting.
let sum = 0;
let n = 10000000;
for (let i = 0; i < n; i = i + 1) {
  sum = sum + i;
}
sum
