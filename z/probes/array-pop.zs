// Array has no way to remove its last element.
//
// Found writing the ZJS interpreter's register and frame stacks. The
// documented Array surface is push / remove / clear; there is no pop,
// truncate, or resize. A stack -- the most common growable-array use in an
// engine -- has to keep its own live-extent counter over a monotonically
// grown array, which is what the engine does.
//
// The spelling below is a proposal only: `pop()` returning Option<T>. Any
// equivalent that removes and returns the last element without an O(n)
// remove-by-index is fine; `truncate(length)` alongside would serve the
// stack case directly.
import console from "std/console";

function main(): i32 {
  let stack = Array<i32>();
  stack.push(1);
  stack.push(2);
  const last = stack.pop();
  const kept = match (last) {
    some(value) => value;
    none => -1;
  };
  if (kept != 2) return 1;
  if (stack.length != 1) return 2;
  console.log("ok");
  return 0;
}
