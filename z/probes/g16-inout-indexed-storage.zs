// G16 — `inout` through indexed storage.  STATUS: proposed
//
// Scope corrected after Codex review at 00864194. `allocate(inout slot.heap)`
// through a plain field projection ALREADY WORKS. What fails is specifically
// the indexed-storage boundary:
//
//     allocate(inout registry.slots[index].heap)   // rejected
//
// Codex classifies this as a conservative implementation restriction, not a
// language rule that mutating APIs must be methods. The method-call form on
// the same projection is accepted, and the engine uses it as the workaround.
// Broader ownership support is left for upstream review.
import console from "std/console";

struct Heap { cells: i32; }
struct Slot { heap: Heap; }
struct Registry { slots: Array<Slot>; }

function allocate(inout heap: Heap): i32 {
  heap.cells = heap.cells + 1;
  return heap.cells;
}

function main(): i32 {
  // Baseline that works today, kept so the probe documents the boundary.
  let single = Slot({ heap: Heap({ cells: 0 }) });
  if (allocate(inout single.heap) != 1) return 1;

  // The indexed case under test.
  let registry = Registry({ slots: Array<Slot>() });
  registry.slots.push(Slot({ heap: Heap({ cells: 0 }) }));
  const handle = allocate(inout registry.slots[0].heap);
  if (handle != 1) return 2;
  console.log("g16 ok");
  return 0;
}
