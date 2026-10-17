// ZJS engine: the C ABI over Z-owned contexts.
//
// Ownership (see docs/lifecycle.md): one root, `Engine`, published once
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
// The root is a compiler-proven shareable class (its one field a Mutex),
// so the runtime may be initialized and shut down on any registered
// thread; the generated header carries no main-thread requirement.

import { Mutex, Once, OnceLifetime } from "std/sync";
import { thread } from "std/thread";
import { Runtime, RunResult } from "./runtime.zs";
import { createEngine, createCoreEngine } from "./builtins.zs";
import { installJson } from "./builtins/json.zs";
import { installRegExp } from "./builtins/regexp.zs";
import { installDate } from "./builtins/date.zs";
import { installCollections } from "./builtins/collections.zs";
import { installPromise } from "./builtins/promise.zs";
import { installReflect } from "./builtins/reflect.zs";
import { installCompiler, installModuleCompiler } from "./compile.zs";
import { evaluateModule, evaluateModuleSource, installModuleSupport } from "./modules.zs";
import { installFileLoader } from "./module_files.zs";
import { writeProgram, writeModule, loadProgram } from "./bytecode_file.zs";
import { Value, undefinedValue } from "./value.zs";
import { sliceBytes } from "./heap.zs";

export struct ContextState {
  hadError: boolean;
  evalCount: u64;
  runtime: Runtime;
  lastResult: Value;
  // The last evaluation ended because the interrupt handler asked it to.
  interrupted: boolean = false;

  function evaluate(inout this, source: Array<u8>): void {
    this.evalCount = this.evalCount + 1;
    const outcome = evaluate(inout this.runtime, move source);
    this.interrupted = this.runtime.endTermination();
    // A termination is an error to the embedder, even one that came while
    // the script's jobs ran, after the script itself had completed.
    this.hadError = outcome.isThrow || this.interrupted;
    this.lastResult = outcome.value;
  }

  // A bytecode file's script, run as evaluate runs source. A file the
  // loader refuses runs nothing and is not an error (zjs.h).
  function evaluateBytecode(inout this, bytes: Slice<u8>): void {
    this.evalCount = this.evalCount + 1;
    const outcome = evaluateBytecode(inout this.runtime, bytes);
    this.interrupted = this.runtime.endTermination();
    this.hadError = outcome.isThrow || this.interrupted;
    this.lastResult = outcome.value;
  }

  // An ES module and the graph it imports, run as evaluate runs a
  // script: from the file at `path`, or from `source` keyed `key`, its
  // imports read from files either way (docs/modules.md).
  function evaluateModule(inout this, path: Array<u8>): void {
    this.evalCount = this.evalCount + 1;
    installModuleCompiler(inout this.runtime);
    installFileLoader(inout this.runtime);
    installModuleSupport(inout this.runtime);
    const outcome = evaluateModule(inout this.runtime, move path);
    this.interrupted = this.runtime.endTermination();
    this.hadError = outcome.isThrow || this.interrupted;
    this.lastResult = outcome.value;
  }

  // The module at `path` and its graph from module files alone: no
  // compiler is installed, so a runtime that is given none (a core
  // context) links no front end for it (zjs_eval_module_bytecode).
  function evaluateModuleBytecode(inout this, path: Array<u8>): void {
    this.evalCount = this.evalCount + 1;
    installFileLoader(inout this.runtime);
    installModuleSupport(inout this.runtime);
    const outcome = evaluateModule(inout this.runtime, move path);
    this.interrupted = this.runtime.endTermination();
    this.hadError = outcome.isThrow || this.interrupted;
    this.lastResult = outcome.value;
  }

  function evaluateModuleSource(inout this, source: Array<u8>, key: Array<u8>): void {
    this.evalCount = this.evalCount + 1;
    installModuleCompiler(inout this.runtime);
    installFileLoader(inout this.runtime);
    installModuleSupport(inout this.runtime);
    const outcome = evaluateModuleSource(inout this.runtime, move key, move source);
    this.interrupted = this.runtime.endTermination();
    this.hadError = outcome.isThrow || this.interrupted;
    this.lastResult = outcome.value;
  }

  // Source compiled here and written as a bytecode file; empty, and an
  // error, when it does not parse or compile.
  function compileToBytecode(inout this, source: Array<u8>): Array<u8> {
    const compiled = compileToBytecode(inout this.runtime, move source);
    this.interrupted = false;
    this.hadError = compiled.length == 0;
    this.lastResult = undefinedValue();
    return compiled;
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
}

const engine = Once<Engine>();

export function initializeRuntime(): OnceLifetime<Engine> on thread.any {
  return engine.initialize(new Engine({
    registry: Mutex(Registry({ slots: Array<Option<Context>>(), generations: Array<u32>(), freeSlots: Array<u32>(), live: 0, created: 0, detached: 0 })),
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
  let runtime = createEngine();
  installCompiler(inout runtime);
  return registerContext(move runtime);
}

// A context with only the core builtins; the embedder installs the
// optional ones it wants (below), and the linker drops the rest.
export c function zjs_z_new_core_context(): usize {
  return registerContext(createCoreEngine());
}

// The compiler, for eval and the Function constructor in a context that
// has evaluated no source: zjs_eval and zjs_compile_to_bytecode bring it
// themselves, and a context that only loads bytecode links none.
export c function zjs_z_install_compiler(handle: usize): void {
  installInto(handle, installCompiler);
}

export c function zjs_z_install_json(handle: usize): void {
  installInto(handle, installJson);
}

export c function zjs_z_install_regexp(handle: usize): void {
  installInto(handle, installRegExp);
}

export c function zjs_z_install_date(handle: usize): void {
  installInto(handle, installDate);
}

export c function zjs_z_install_collections(handle: usize): void {
  installInto(handle, installCollections);
}

export c function zjs_z_install_promise(handle: usize): void {
  installInto(handle, installPromise);
}

export c function zjs_z_install_reflect(handle: usize): void {
  installInto(handle, installReflect);
}

// Run an installer on a live context, under its lock; installing a
// feature twice does nothing the second time.
function installInto(handle: usize, install: (inout runtime: Runtime) => void): void {
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        install(inout state.runtime);
      });
    }
    none => {
    }
  }
}

function registerContext(runtime: Runtime): usize {
  const current = engine.get();
  // The runtime is built outside the registry lock; only the slot
  // assignment holds it.
  const context = new Context({
    state: Mutex(ContextState({ hadError: false, evalCount: 0, runtime: move runtime, lastResult: undefinedValue() })),
  });
  return current.registry.withLock((inout registry): usize => {
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

function nativeAlloc(count: usize): usize = raw c {
  return (uintptr_t)malloc(count == 0 ? 1 : count);
}

function nativeStoreByte(buffer: usize, index: usize, value: u8): void = raw c {
  ((uint8_t *)buffer)[index] = value;
}

function nativeStoreLength(address: usize, length: usize): void = raw c {
  if (address != 0) *(size_t *)address = (size_t)length;
}

// A bytecode file arrives as a borrowed byte slice and is copied, as
// source is (below).
export c function zjs_z_eval_bytecode(handle: usize, data: Slice<u8>): void {
  const bytes = sliceToBytes(data);
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        state.evaluateBytecode(bytes);
      });
    }
    none => {
    }
  }
}

// The bytecode file goes back in memory the host frees with free(), its
// length through `lengthOut` (a size_t address); 0 and a length of 0 when
// the source does not parse or compile.
export c function zjs_z_compile_to_bytecode(handle: usize, source: Slice<u8>, lengthOut: usize): usize {
  nativeStoreLength(lengthOut, 0);
  const bytes = sliceToBytes(source);
  const found = retain(handle);
  return match (found) {
    some(context) => context.state.withLock((inout state): usize => {
      const byteCount = bytes.length;
      const compiled = state.compileToBytecode(sliceBytes(in bytes, 0, byteCount));
      if (compiled.length == 0) return 0;
      const buffer = nativeAlloc(compiled.length);
      let index: usize = 0;
      while (index < compiled.length) {
        nativeStoreByte(buffer, index, compiled[index]);
        index = index + 1;
      }
      nativeStoreLength(lengthOut, compiled.length);
      return buffer;
    });
    none => 0;
  };
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

// zjs_eval_module: the module at `path`, read as a file.
export c function zjs_z_eval_module(handle: usize, path: Slice<u8>): void {
  const bytes = sliceToBytes(path);
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        const byteCount = bytes.length;
        state.evaluateModule(sliceBytes(in bytes, 0, byteCount));
      });
    }
    none => {
    }
  }
}

// zjs_eval_module_bytecode: the module at `path`, its graph's modules
// module files.
export c function zjs_z_eval_module_bytecode(handle: usize, path: Slice<u8>): void {
  const bytes = sliceToBytes(path);
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        const byteCount = bytes.length;
        state.evaluateModuleBytecode(sliceBytes(in bytes, 0, byteCount));
      });
    }
    none => {
    }
  }
}

// zjs_eval_module_source: `source` as the module keyed `key`.
export c function zjs_z_eval_module_source(handle: usize, source: Slice<u8>, key: Slice<u8>): void {
  const bytes = sliceToBytes(source);
  const keyBytes = sliceToBytes(key);
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        const byteCount = bytes.length;
        const keyCount = keyBytes.length;
        state.evaluateModuleSource(sliceBytes(in bytes, 0, byteCount), sliceBytes(in keyBytes, 0, keyCount));
      });
    }
    none => {
    }
  }
}

export function sliceToBytes(source: Slice<u8>): Array<u8> {
  let bytes = Array<u8>.withCapacity(source.length);
  let index: usize = 0;
  const count = source.length;
  while (index < count) {
    bytes.push(source[index]);
    index = index + 1;
  }
  return bytes;
}

// The embedder's interrupt handler (zjs_set_interrupt_handler): a C
// function's address and its argument, as words; 0 removes it. The engine
// calls it on the thread that runs the context's JavaScript.
export c function zjs_z_set_interrupt_handler(handle: usize, handler: usize, opaque: usize): void {
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        state.runtime.setInterruptHandler(handler, opaque);
      });
    }
    none => {
    }
  }
}

// 1 when the last evaluation ended because the interrupt handler asked.
export c function zjs_z_was_interrupted(handle: usize): i32 {
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): i32 => state.interrupted ? 1 : 0);
    }
    none => {
      return 0;
    }
  }
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

// Parse and compile one program against a runtime, and write it as a
// bytecode file (docs/bytecode-files.md); empty when it does not parse
// or compile, or has a part no file can hold. Nothing runs.
export function compileToBytecode(inout runtime: Runtime, source: Array<u8>): Array<u8> {
  installCompiler(inout runtime);
  const first = runtime.functions.length;
  const functionIndex = runtime.compileScript(move source);
  if (functionIndex < 0) return Array<u8>();
  return writeProgram(inout runtime, u32(first), u32(functionIndex));
}

// A module's source compiled here and written as a module file
// (docs/modules.md); empty when it does not parse or compile, or has a
// part no file can hold. Its imports are not read: each is a file of its
// own, source or bytecode.
export function compileModuleToBytecode(inout runtime: Runtime, source: Array<u8>): Array<u8> {
  installModuleCompiler(inout runtime);
  const first = runtime.functions.length;
  const compile = runtime.moduleCompiler;
  let compiled = compile(inout runtime, move source);
  if (compiled.index < 0) return Array<u8>();
  return writeModule(inout runtime, u32(first), u32(compiled.index), in compiled.info);
}

// Load a bytecode file and run its script as evaluate runs one compiled
// from source, its jobs after it. A file the loader refuses runs
// nothing: the result is undefined and not a throw (zjs.h).
export function evaluateBytecode(inout runtime: Runtime, bytes: Slice<u8>): RunResult {
  const script = loadProgram(inout runtime, bytes);
  if (script < 0) return RunResult({ isThrow: false, value: undefinedValue() });
  const outcome = runtime.run(u32(script));
  runtime.runJobs();
  return outcome;
}

// Parse, compile, and run one program against a runtime. Source the
// embedder evaluates brings the compiler with it, so its eval and
// Function constructor have one too.
export function evaluate(inout runtime: Runtime, source: Array<u8>): RunResult {
  installCompiler(inout runtime);
  const functionIndex = runtime.compileScript(move source);
  if (functionIndex < 0) return RunResult({ isThrow: true, value: runtime.compileFailure(functionIndex) });
  const outcome = runtime.run(u32(functionIndex));
  // The script's jobs (promise reactions, async continuations) run once
  // it completes, before control returns to the host: a context never
  // holds pending jobs between calls.
  runtime.runJobs();
  return outcome;
}
