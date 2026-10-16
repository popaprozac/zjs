// std/memory.replace on an Array field mis-infers its result type in codegen.
//
// Found writing the ZJS parser (swapping a token stream for a template
// substitution). `z check` accepts this file. The generated C then declares
// the result as `int32_t` and fails to compile:
//
//   initializing 'int32_t' with an expression of incompatible type
//   'Z_DynamicArray___z_dynamic_array_3a_Item'
//
// Writing the annotation out -- `let previous: Array<Item> = replace(...)`
// -- compiles and runs, so the inferred type is wrong only in the emitter.
// Same class of diagnostic escape as the module-const-string-method probe.
//
// Expected: prints "ok 1". Actual: BACKEND-REJECTED.
import console from "std/console";
import { replace } from "std/memory";

struct Item { value: i32; }

struct Holder {
  items: Array<Item>;

  function swap(inout this, fresh: Array<Item>): usize {
    let previous = replace(inout this.items, move fresh);
    return previous.length;
  }
}

function main(): i32 {
  let holder = Holder({ items: Array<Item>() });
  holder.items.push(Item({ value: 1 }));
  const count = holder.swap(Array<Item>());
  if (count != 1) return 1;
  console.log(`ok ${count}`);
  return 0;
}
