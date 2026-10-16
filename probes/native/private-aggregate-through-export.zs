// An exported struct may hold, in a field, an array of a struct its module
// does not export, and a module that imports the exported struct may read
// that field's elements without naming the private type. The engine's
// heap keeps its hidden classes this way behind the exported Heap, and
// the runtime walks them to report its statistics.
import console from "std/console";
import { Holder, createHolder } from "./modules/private-aggregate.zs";

function main(): i32 {
  let holder = createHolder();
  holder.add(2);
  holder.add(3);
  if (holder.total() != 5) return 1;
  let sum: i32 = 0;
  let index: usize = 0;
  while (index < holder.items.length) {
    sum = sum + holder.items[index].value;
    index = index + 1;
  }
  if (sum != 5) return 2;
  console.log("ok");
  return 0;
}
