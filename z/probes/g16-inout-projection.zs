// G16 — `inout` on a place expression.  STATUS: open (may be deliberate)
//
// An engine reaches through collections to mutate nested state constantly.
// Today `inout` requires a plain binding, so the free-function form below is
// rejected and every mutating API has to be a method on the receiver.
//
// If this rule is intentional, the resolution is documentation plus a
// diagnostic that names the method workaround -- not necessarily a change.
import console from "std/console";

struct Heap { cells: i32; }
struct Slot { heap: Heap; }
struct Registry { slots: Array<Slot>; }

function allocate(inout heap: Heap): i32 {
  heap.cells = heap.cells + 1;
  return heap.cells;
}

function main(): i32 {
  let registry = Registry({ slots: Array<Slot>() });
  registry.slots.push(Slot({ heap: Heap({ cells: 0 }) }));
  const handle = allocate(inout registry.slots[0].heap);
  if (handle != 1) return 1;
  console.log("g16 ok");
  return 0;
}
