// An indexing form that skips the bounds check where the program has
// established the invariant.
//
// Found in the ZJS interpreter loop. Every array index lowers to a
// compare-and-abort, and the loop does two to four per bytecode
// instruction (fetch, register reads, register write). Rebuilding the
// generated C with the check removed, and nothing else, made the engine
// 7 to 13 percent faster across four benchmarks. The register window
// and the code segment are validated once per frame push; re-checking
// each access buys nothing there.
//
// The spelling below is a proposal only: `atUnchecked(i)` on Array,
// paired with a debug-build check. An `unsafe` index expression or a
// per-function attribute that elides checks in release would serve too.
import console from "std/console";

function sum(in values: Array<i32>, count: usize): i32 {
  // Invariant established here, once: count <= values.length.
  if (count > values.length) return -1;
  let total: i32 = 0;
  let index: usize = 0;
  while (index < count) {
    total = total + values.atUnchecked(index);
    index = index + 1;
  }
  return total;
}

function main(): i32 {
  let values = Array<i32>();
  values.push(1);
  values.push(2);
  values.push(3);
  if (sum(in values, 3) != 6) return 1;
  if (sum(in values, 5) != -1) return 2;
  console.log("ok");
  return 0;
}
