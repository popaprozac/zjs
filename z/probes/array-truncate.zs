// A table that grew to millions of entries in a burst and now needs a
// thousand can only be shortened an element at a time (`pop`, each one
// returning an Option to bind) or emptied (`clear`). The engine keeps a
// logical extent beside such an array instead and overwrites what is
// above it. This probe asks only for the cut; reading capacity is a
// separate question with its own probe.
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
  table.push(9);
  if (table[2] != 9) return 2;
  console.log("ok");
  return 0;
}
