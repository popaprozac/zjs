// Appending one value many times in one call, which a copyable element
// type can lower to one capacity check and a fill. The engine pushed each
// slot of a new cell as `undefined`, and every hash index as a loop of
// empty markers, one element and one capacity check at a time.
//
// Landed in z-lang as `Array<T>.appendRepeated(value: T, count: usize)`
// for cleanup-free T. A run of sixteen or fewer is stored inline: as a
// fill loop, clang calls memset_pattern16, which costs more than the few
// slots of a cell (closures +4% in cycles when it did).
import console from "std/console";

function main(): i32 {
  let slots = Array<u64>.withCapacity(4);
  slots.push(1);
  slots.appendRepeated(7, 3);
  if (slots.length != 4 || slots.capacity != 4) return 1;
  if (slots[0] != 1 || slots[1] != 7 || slots[3] != 7) return 2;
  slots.appendRepeated(9, 40);
  if (slots.length != 44 || slots[3] != 7 || slots[4] != 9 || slots[43] != 9) return 3;
  slots.appendRepeated(0, 0);
  if (slots.length != 44) return 4;
  console.log("ok");
  return 0;
}
