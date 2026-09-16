// ZJS engine: the C ABI over Z-owned contexts.
//
// Ownership (see z/docs/lifecycle.md): one root, `Engine`, published once
// and retained by the generated runtime; it owns a registry of contexts.
// A context is an ARC class whose one field is a Mutex around its state
// (the Runtime and the last result). A handle packs the context's slot
// and that slot's generation into the pointer-shaped token the frozen
// zjs.h promises; a stale token is refused by every call.
//
// Locking: an ABI call takes the registry lock only to look its context
// up and retain it, then works under the context's own lock. Independent
// contexts therefore run concurrently on host threads; calls on one
// context serialize. Admission is the successful lookup: a call admitted
// before `free` finishes, even one still waiting for the context lock.
// `free` detaches the registry's reference under the registry lock and
// drops it after; the Runtime and its native resources are destroyed by
// whichever reference drops last, never under the registry lock.
//
// The root still carries a main-bound field it never reads: Once<T>
// requires a main-bound class (ledger G36, probe shareable-once-root).
// Until that lands, initialization must happen on the main thread.

import { Mutex, Once, OnceLifetime } from "std/sync";
import { thread } from "std/thread";
import { Runtime, RunResult } from "./runtime.zs";
import { createEngine } from "./builtins.zs";
import { parseProgram } from "./parser.zs";
import { compileProgram } from "./compiler.zs";
import { Value, undefinedValue } from "./value.zs";
import { sliceBytes } from "./heap.zs";

export struct ContextState {
  hadError: boolean;
  evalCount: u64;
  runtime: Runtime;
  lastResult: Value;

  function evaluate(inout this, source: Array<u8>): void {
    this.evalCount = this.evalCount + 1;
    const outcome = evaluate(inout this.runtime, move source);
    this.hadError = outcome.isThrow;
    this.lastResult = outcome.value;
  }
}

export class Context {
  readonly state: Mutex<ContextState>;
}

// A slot's generation is part of its handle; freeing bumps it, so a
// reused slot never answers an old handle. A slot whose generations are
// exhausted is retired rather than wrapped.
const GENERATION_RETIRED: u32 = 4294967295;
const GENERATION_LAST: u32 = 4294967294;

struct Registry {
  slots: Array<Option<Context>>;
  generations: Array<u32>;
  freeSlots: Array<u32>;
  live: u32;
  created: u64;
  detached: u64;
}

export class Engine {
  readonly registry: Mutex<Registry>;
  publicationEpoch: i32 on thread.main;
}

const engine = Once<Engine>();

export function initializeRuntime(): OnceLifetime<Engine> on thread.main {
  return engine.initialize(new Engine({
    registry: Mutex(Registry({ slots: Array<Option<Context>>(), generations: Array<u32>(), freeSlots: Array<u32>(), live: 0, created: 0, detached: 0 })),
    publicationEpoch: 1,
  }));
}

// --- Handles ---
//
// low 32 bits: slot index + 1 (zero is the null handle); high 32 bits:
// the slot's generation at creation. This needs a 64-bit host word; the
// shim asserts it.

function packHandle(index: u32, generation: u32): usize {
  return usize(index + 1) | (usize(generation) << 32);
}

function handleIndex(handle: usize): u32 {
  return u32(handle & 4294967295);
}

function handleGeneration(handle: usize): u32 {
  return u32(handle >> 32);
}

// The context a handle names, retained, or none: the admission step.
export function retain(handle: usize): Option<Context> {
  const index = handleIndex(handle);
  const generation = handleGeneration(handle);
  if (index == 0) return Option<Context>.none;
  const current = engine.get();
  return current.registry.withLock((in registry): Option<Context> => {
    const at = usize(index - 1);
    if (at >= registry.slots.length) return Option<Context>.none;
    if (registry.generations[at] != generation) return Option<Context>.none;
    match (registry.slots[at]) {
      some(context) => {
        return Option<Context>.some(context);
      }
      none => {
        return Option<Context>.none;
      }
    }
  });
}

export c function zjs_z_new_context(): usize {
  const current = engine.get();
  return current.registry.withLock((inout registry): usize => {
    // Built under the lock: a class reference captured by the lock
    // callback from outside is never released (ledger G37).
    const context = new Context({
      state: Mutex(ContextState({ hadError: false, evalCount: 0, runtime: createEngine(), lastResult: undefinedValue() })),
    });
    registry.live = registry.live + 1;
    registry.created = registry.created + 1;
    match (registry.freeSlots.pop()) {
      some(reused) => {
        registry.slots[usize(reused)] = Option<Context>.some(context);
        return packHandle(reused, registry.generations[usize(reused)]);
      }
      none => {
        registry.slots.push(Option<Context>.some(context));
        registry.generations.push(0);
        return packHandle(u32(registry.slots.length - 1), 0);
      }
    }
  });
}

// Detach under the registry lock; destroy after it. A call admitted
// before this finishes completes with its own reference.
export c function zjs_z_free_context(handle: usize): void {
  const index = handleIndex(handle);
  const generation = handleGeneration(handle);
  if (index == 0) return;
  const current = engine.get();
  const detached = current.registry.withLock((inout registry): Option<Context> => {
    const at = usize(index - 1);
    if (at >= registry.slots.length) return Option<Context>.none;
    if (registry.generations[at] != generation) return Option<Context>.none;
    let taken = Option<Context>.none;
    match (registry.slots[at]) {
      some(context) => {
        taken = Option<Context>.some(context);
      }
      none => {
        return Option<Context>.none;
      }
    }
    registry.slots[at] = Option<Context>.none;
    registry.live = registry.live - 1;
    registry.detached = registry.detached + 1;
    if (registry.generations[at] >= GENERATION_LAST) {
      registry.generations[at] = GENERATION_RETIRED;
    } else {
      registry.generations[at] = registry.generations[at] + 1;
      registry.freeSlots.push(u32(at));
    }
    return taken;
  });
  // `detached` drops here, outside the registry lock: if no evaluation
  // holds the context, this destroys the runtime and its native state.
  const dropped = detached;
}

// Source arrives as a borrowed byte slice and is copied: JavaScript
// source is bytes to the engine and is never validated as UTF-8, so a
// script that is not text cannot abort the host.
export c function zjs_z_eval(handle: usize, source: Slice<u8>): void {
  const bytes = sliceToBytes(source);
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        // The lock callback borrows `bytes`; the evaluation owns a copy.
        const byteCount = bytes.length;
        state.evaluate(sliceBytes(in bytes, 0, byteCount));
      });
    }
    none => {
    }
  }
}

export function sliceToBytes(source: Slice<u8>): Array<u8> {
  let bytes = Array<u8>();
  let index: usize = 0;
  const count = source.length;
  while (index < count) {
    bytes.push(source[index]);
    index = index + 1;
  }
  return bytes;
}

// 1 after a throw, and for a handle that names no context.
export c function zjs_z_had_error(handle: usize): i32 {
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): i32 => state.hadError ? 1 : 0);
    }
    none => {
      return 1;
    }
  }
}

// The completion value (or thrown value) of the last eval, as NaN-box bits.
export c function zjs_z_last_result_bits(handle: usize): u64 {
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): u64 => state.lastResult.bits);
    }
    none => {
      return 0;
    }
  }
}

// Live heap cells in a context, for the harness.
export c function zjs_z_heap_cells(handle: usize): u32 {
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): u32 => state.runtime.heap.liveCells());
    }
    none => {
      return 0;
    }
  }
}

export c function zjs_z_eval_count(handle: usize): u64 {
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): u64 => state.evalCount);
    }
    none => {
      return 0;
    }
  }
}

// Lifecycle counters, for the harness: contexts in the registry now,
// ever created, and detached by free (destroyed once their last
// reference dropped; the native side counts its own).
export c function zjs_z_live_contexts(): u32 {
  const current = engine.get();
  return current.registry.withLock((in registry): u32 => registry.live);
}

export c function zjs_z_created_contexts(): u64 {
  const current = engine.get();
  return current.registry.withLock((in registry): u64 => registry.created);
}

export c function zjs_z_detached_contexts(): u64 {
  const current = engine.get();
  return current.registry.withLock((in registry): u64 => registry.detached);
}

// Parse, compile, and run one program against a runtime.
export function evaluate(inout runtime: Runtime, source: Array<u8>): RunResult {
  const parsed = parseProgram(move source, false);
  if (parsed.hadError) {
    // The reference reports both phases as a SyntaxError whose message
    // names the phase; test262 tooling reads the phase from it.
    const message: String = "parse error";
    return RunResult({ isThrow: true, value: runtime.syntaxError(in message) });
  }
  const functionIndex = compileProgram(in parsed.parser, parsed.root, inout runtime);
  if (functionIndex < 0) {
    const message: String = "compile error";
    return RunResult({ isThrow: true, value: runtime.syntaxError(in message) });
  }
  const outcome = runtime.run(u32(functionIndex));
  // The script's jobs (promise reactions, async continuations) run once
  // it completes, before control returns to the host: a context never
  // holds pending jobs between calls.
  runtime.runJobs();
  return outcome;
}
