// A call-scoped range of an array whose elements are a struct, passed
// where a Slice of that struct is expected.
//
// Found saving a generator's registers (engine/runtime.zs,
// suspendGenerator): the register window, a range of an array of the
// engine's value struct, goes to the heap as one run:
//
//   this.heap.setSlots(saved, this.regStack.slice(base, base + count));
//
// Stage 0 checked it clean and then emitted C that clang refused,
// "arithmetic on a pointer to an incomplete type": the range helper came
// before the struct's definition. A range of an array of integers or
// bytes worked, and the native compiler built the struct case.
import console from "std/console";

struct Pair {
  first: u32;
  second: u32;
}

function total(pairs: Slice<Pair>): u32 {
  let sum: u32 = 0;
  let index: usize = 0;
  while (index < pairs.length) {
    sum = sum + pairs[index].first + pairs[index].second;
    index = index + 1;
  }
  return sum;
}

function main(): i32 {
  let pairs = Array<Pair>();
  pairs.push(Pair({ first: 1, second: 2 }));
  pairs.push(Pair({ first: 3, second: 4 }));
  pairs.push(Pair({ first: 5, second: 6 }));
  if (total(pairs) != 21) return 1;
  if (total(pairs.slice(1, 3)) != 18) return 2;
  if (total(pairs.slice(3, 3)) != 0) return 3;
  console.log("ok");
  return 0;
}
