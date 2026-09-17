// An array reports the capacity it holds: what it was made or reserved
// for, unchanged by pushes within it and kept by `clear`. The engine
// reads it to report the storage it retains, as distinct from what it
// has in use.
import console from "std/console";
function main(): i32 {
  let table = Array<u32>.withCapacity(64);
  if (table.capacity < 64) return 1;
  const made = table.capacity;
  let i: u32 = 0;
  while (i < 64) {
    table.push(i);
    i = i + 1;
  }
  if (table.capacity != made) return 2;
  table.clear();
  if (table.length != 0 || table.capacity != made) return 3;
  console.log("ok");
  return 0;
}
