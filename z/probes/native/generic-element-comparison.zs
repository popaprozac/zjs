// A generic function over Array<T> may compare two elements: every
// instantiation the program makes is of a comparable T.
import console from "std/console";
function sameAt<T>(in left: Array<T>, in right: Array<T>, index: usize): boolean {
  return left[index] == right[index];
}
function main(): i32 {
  let bytes = Array<u8>.withCapacity(2);
  bytes.push(1);
  bytes.push(2);
  let units = Array<u16>.withCapacity(2);
  units.push(1);
  units.push(3);
  if (!sameAt<u8>(bytes, bytes, 1)) return 1;
  if (sameAt<u16>(units, units, 0) != true) return 2;
  console.log("ok");
  return 0;
}
