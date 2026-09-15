// ZJS engine — Z implementation, Phase 1 scaffold.
//
// This publishes the four C ABI entry points the test262 harness uses, over
// a Z-owned context registry. No JavaScript is evaluated yet: `zjs_z_eval`
// records "not implemented", so a full test262 run reports 0 passed. That is
// the Phase 1 goal -- prove the loop, then make the number climb.
//
// Context escape mechanism (a real design decision, not a stub):
// contexts live in a Z-owned Array behind a Mutex, published once through the
// manifest runtime root. What crosses the ABI is a *handle*, not a pointer --
// the same choice the spike settled for heap cells. No raw pointer touches Z
// state, and `ZjsContext*` stays opaque to the host because the shim casts
// the handle into the pointer-shaped type the frozen zjs.h promises.
//
// Handles are 1-based so that 0 is a valid "null context" for C callers.

import { Mutex, Once, OnceLifetime } from "std/sync";
import { thread } from "std/thread";
import { Heap, createHeap, TAG_OBJECT } from "./heap.zs";

struct ContextSlot {
  live: boolean;
  hadError: boolean;
  evalCount: u64;
  heap: Heap;
}

struct Registry {
  slots: Array<ContextSlot>;
}

// Finding G8, sharpened by Phase 1. `Once<T>` accepts only a class whose
// lifecycle is main-bound -- but marking the whole class `on thread.main`
// then makes every field main-affine, and `export c function` rejects
// executor-affine functions, so the C ABI becomes unreachable.
//
// The way through is a *vestigial* main-bound field: it satisfies Once's
// requirement while `registry` stays an ordinary thread-shareable Mutex.
// That works, but a class needing a field it never reads in order to be
// publishable is a design smell, and it is recorded as such.
class Engine {
  readonly registry: Mutex<Registry>;
  publicationEpoch: i32 on thread.main;
}

const engine = Once<Engine>();

function initializeRuntime(): OnceLifetime<Engine> on thread.main {
  return engine.initialize(new Engine({
    registry: Mutex(Registry({ slots: Array<ContextSlot>() })),
    publicationEpoch: 1,
  }));
}

export c function zjs_z_new_context(): usize {
  const current = engine.get();
  return current.registry.withLock((inout registry): usize => {
    registry.slots.push(ContextSlot({
      live: true,
      hadError: false,
      evalCount: 0,
      heap: createHeap(),
    }));
    return registry.slots.length;
  });
}

export c function zjs_z_free_context(handle: usize): void {
  if (handle == 0) return;
  const current = engine.get();
  current.registry.withLock((inout registry): void => {
    if (handle > registry.slots.length) return;
    registry.slots[handle - 1].live = false;
  });
}

export c function zjs_z_eval(handle: usize, source: String): void {
  if (handle == 0) return;
  const current = engine.get();
  current.registry.withLock((inout registry): void => {
    if (handle > registry.slots.length) return;
    const index = handle - 1;
    registry.slots[index].evalCount = registry.slots[index].evalCount + 1;
    // Phase 2: still no evaluation, but the context's heap is real. Allocate
    // one object cell per eval so the ABI can prove per-context heap state.
    const unused = registry.slots[index].heap.allocate(TAG_OBJECT, 4);
    registry.slots[index].hadError = source.byteLength >= 0;
  });
}

export c function zjs_z_had_error(handle: usize): i32 {
  if (handle == 0) return 1;
  const current = engine.get();
  return current.registry.withLock((in registry): i32 => {
    if (handle > registry.slots.length) return 1;
    return registry.slots[handle - 1].hadError ? 1 : 0;
  });
}

// Scaffold visibility: lets the harness prove per-context heap state really
// crossed the ABI and stayed independent between contexts.
export c function zjs_z_heap_cells(handle: usize): u32 {
  if (handle == 0) return 0;
  const current = engine.get();
  return current.registry.withLock((in registry): u32 => {
    if (handle > registry.slots.length) return 0;
    return registry.slots[handle - 1].heap.liveCells();
  });
}

// Scaffold visibility: lets the harness prove state really crossed the ABI.
export c function zjs_z_eval_count(handle: usize): u64 {
  if (handle == 0) return 0;
  const current = engine.get();
  return current.registry.withLock((in registry): u64 => {
    if (handle > registry.slots.length) return 0;
    return registry.slots[handle - 1].evalCount;
  });
}
