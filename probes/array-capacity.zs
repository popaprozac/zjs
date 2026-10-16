// Building a string of known length pushes one element at a time and
// regrows along the way; a capacity reservation would make it one
// allocation. The reference says a future operation will have a name.
import console from "std/console";
function main(): i32 {
  let bytes = Array<u8>.withCapacity(1024);
  let i: usize = 0;
  while (i < 1024) {
    bytes.push(u8(i & 255));
    i = i + 1;
  }
  if (bytes.length != 1024) return 1;
  console.log("ok");
  return 0;
}
