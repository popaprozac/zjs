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
import { Runtime, RunResult, createRuntime } from "./runtime.zs";
import { parseProgram } from "./parser.zs";
import { compileProgram } from "./compiler.zs";
import { Value, undefinedValue } from "./value.zs";

struct ContextSlot {
  live: boolean;
  hadError: boolean;
  evalCount: u64;
  runtime: Runtime;
  lastResult: Value;

  // A method, because the registry reaches a slot through an index and Z
  // accepts a method call on that projection where it rejects `inout`.
  function evaluate(inout this, source: String): void {
    this.evalCount = this.evalCount + 1;
    const outcome = evaluate(inout this.runtime, move source);
    this.hadError = outcome.isThrow;
    this.lastResult = outcome.value;
  }
}

struct Registry {
  slots: Array<ContextSlot>;
}

// `Once<T>` accepts only a class whose lifecycle is main-bound -- but
// marking the whole class `on thread.main`
// then makes every field main-affine, and `export c function` rejects
// executor-affine functions, so the C ABI becomes unreachable.
//
// The way through is a *vestigial* main-bound field: it satisfies Once's
// requirement while `registry` stays an ordinary thread-shareable Mutex.
// That works, but a class needing a field it never reads in order to be
// publishable is a smell, and the worker model will need a root that is
// publishable without main-binding.
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
      runtime: createRuntime(),
      lastResult: undefinedValue(),
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
    // The lock callback captures `source` as a borrow and cannot take it
    // over, so the slot receives an owned copy.
    registry.slots[handle - 1].evaluate(source.copyBytes(0, source.byteLength));
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

// The completion value (or thrown value) of the last eval, as NaN-box bits.
export c function zjs_z_last_result_bits(handle: usize): u64 {
  if (handle == 0) return 0;
  const current = engine.get();
  return current.registry.withLock((in registry): u64 => {
    if (handle > registry.slots.length) return 0;
    return registry.slots[handle - 1].lastResult.bits;
  });
}

// Live heap cells in a context, for the harness.
export c function zjs_z_heap_cells(handle: usize): u32 {
  if (handle == 0) return 0;
  const current = engine.get();
  return current.registry.withLock((in registry): u32 => {
    if (handle > registry.slots.length) return 0;
    return registry.slots[handle - 1].runtime.heap.liveCells();
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

// Parse, compile, and run one program against a runtime.
export function evaluate(inout runtime: Runtime, source: String): RunResult {
  const parsed = parseProgram(move source, false);
  if (parsed.hadError) {
    // SyntaxError; Error objects do not exist yet.
    return RunResult({ isThrow: true, value: undefinedValue() });
  }
  const functionIndex = compileProgram(in parsed.parser, parsed.root, inout runtime);
  if (functionIndex < 0) return RunResult({ isThrow: true, value: undefinedValue() });
  return runtime.run(u32(functionIndex));
}
