// Appending a run of elements from another array or slice in one call,
// which a copyable element type can lower to a single memcpy after one
// capacity check. The engine copies bytes and units element by element
// with a push each, and a push checks capacity every time: joining two
// strings, extending a string buffer another concatenation made, building
// JSON and array-join output, growing an object's slots.
//
// The spelling below is a proposal only: `append(from: Slice<T>)` on
// Array<T> for copyable T. A `copy(into:)` on Slice, or anything else that
// moves a run of copyable elements without a per-element loop, would serve.
import console from "std/console";

function main(): i32 {
  let target = Array<u8>.withCapacity(4);
  target.push(1);
  let source = Array<u8>.withCapacity(3);
  source.push(2);
  source.push(3);
  source.push(4);
  target.append(source);
  if (target.length != 4) return 1;
  if (target[0] != 1 || target[1] != 2 || target[3] != 4) return 2;
  target.append(source);
  if (target.length != 7 || target[6] != 4) return 3;
  console.log("ok");
  return 0;
}
