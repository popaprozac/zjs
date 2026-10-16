// Recursive Fibonacci — the classic call-overhead microbench. Each
// fib(n) makes 2 calls; depth 32 ≈ 7M calls. Stresses Op::Invoke,
// stack/register-frame setup, parameter copy, and ReturnStmt. JIT
// engines (node/bun) should stretch their legs here.
function fib(n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}
fib(32)
