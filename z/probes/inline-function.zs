// A declaration-site request that a function be inlined into its callers.
// The engine's dispatch loop is one very large function, and clang will
// not inline even two-line helpers into it (integer addition, the frame
// protocol); forcing five of them inline measured calls -9%, properties
// and closures -5%. Copying their bodies into the loop by hand would
// duplicate the logic.
//
// Landed in z-lang 46fa78ca as `inline function`, with `cold function`
// beside it: contextual keywords lowered to `always_inline` and to `cold`,
// `noinline`, `minsize`.
import console from "std/console";

inline function add(a: i32, b: i32): i32 {
  return a + b;
}

function main(): i32 {
  let total: i32 = 0;
  let i: i32 = 0;
  while (i < 10) {
    total = add(total, i);
    i = i + 1;
  }
  if (total != 45) return 1;
  console.log("ok");
  return 0;
}
