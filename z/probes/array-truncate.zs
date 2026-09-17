// A table that grew to six million entries in a burst and now needs a
// thousand can only be shortened an element at a time (`pop`, each one
// returning an Option to bind) or emptied (`clear`); its capacity cannot
// be read either. The engine keeps a logical extent beside the array
// instead and overwrites what is above it.
import console from "std/console";
function main(): i32 {
  let table = Array<u32>.withCapacity(8);
  let i: u32 = 0;
  while (i < 8) {
    table.push(i);
    i = i + 1;
  }
  table.truncate(2);
  if (table.length != 2) return 1;
  if (table.capacity < 8) return 2;
  table.push(9);
  if (table[2] != 9) return 3;
  console.log("ok");
  return 0;
}
