// An `unsafe { select ...; }` expression as the value of an assignment.
//
// Found in the collector's young sweep (engine/heap.zs, sweepYoung), which
// reads the free list unchecked inside a loop into a variable declared
// before it:
//
//   handle = unsafe { select this.freeHandles.uncheckedAt(index); };
//
// Stage 0 accepts it. The native compiler stops with an internal compiler
// error: "native lowering does not support unsafeExpression expression
// ... yet while lowering statement". The same expression as a `const`
// initializer or a `return` value lowers natively, and the engine uses
// both.
import console from "std/console";

function main(): i32 {
  let values = Array<u32>();
  values.push(7);
  values.push(9);
  let got: u32 = 0;
  let index: usize = 0;
  while (index < values.length) {
    got = unsafe { select values.uncheckedAt(index); };
    index = index + 1;
  }
  if (got != 9) return 1;
  console.log("ok");
  return 0;
}
