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
import { replace } from "std/memory";
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
import { Value, undefinedValue, deletedValue, cellValue, int32Value, doubleValue, asCell, isCell, isNumber, isNull, isUndefined, isDeleted, isHole, VALUE_NULL, VALUE_FALSE, VALUE_TRUE, VALUE_UNDEFINED } from "./value.zs";
import { sliceBytes, TAG_STRING, TAG_OBJECT, TAG_ARRAY, TAG_FUNCTION, TAG_HOST_FUNCTION, TAG_CLOSURE, TAG_PROMISE, TAG_REGEXP } from "./heap.zs";

export struct ContextState {
  hadError: boolean;
  evalCount: u64;
  runtime: Runtime;
  lastResult: Value;
  // The last evaluation ended because the interrupt handler asked it to.
  interrupted: boolean = false;
  // After the embedder read or wrote a property, which may have run a
  // getter or a setter: a throw left pending, or a termination, becomes
  // the context's error as an evaluation's does, and false comes back.
  // Without one the error of an earlier call stays as it was.
  function settle(inout this): boolean {
    const threw = this.runtime.pendingThrow;
    let thrown = undefinedValue();
    if (threw) thrown = this.runtime.takePending();
    const interrupted = this.runtime.endTermination();
    if (!threw && !interrupted) return true;
    this.hadError = true;
    this.interrupted = interrupted;
    this.lastResult = thrown;
    // Where a run keeps what it threw: a root until the next run.
    this.runtime.lastResult = thrown;
    return false;
  }

  // zjs_call: the function called, then the jobs it queued, as an
  // evaluation runs a script and then its jobs. Its value, or what it
  // threw, is the context's last result.
  function call(inout this, callee: Value, thisValue: Value, args: Array<Value>): void {
    this.hadError = false;
    this.interrupted = false;
    let result = this.runtime.callValue(callee, thisValue, move args);
    const threw = this.runtime.pendingThrow;
    if (threw) result = this.runtime.takePending();
    this.runtime.pushTempRoot(result);
    this.runtime.runJobs();
    this.runtime.popTempRoot();
    this.interrupted = this.runtime.endTermination();
    this.hadError = threw || this.interrupted;
    this.lastResult = result;
    this.runtime.lastResult = result;
  }

  // zjs_string_bytes: the UTF-8 copies of strings lent to the embedder,
  // in a table with open addressing: a string's cell (0 for a free
  // place), its copy's address, and the copy's length.
  textCells: Array<u32> = Array<u32>();
  textBuffers: Array<usize> = Array<usize>();
  textLengths: Array<usize> = Array<usize>();
  textCount: usize = 0;

  // A string's text as UTF-8 for the embedder: the address of a copy
  // with a NUL after it, its length in bytes written at `lengthOut`.
  // The engine's own storage will not do: it holds bytes or 16-bit
  // units, not UTF-8, and a small string's moves. The copy stays where
  // it is for as long as the string lives: the heap lists the lent
  // strings that die (lendString), and their copies are freed here
  // before any is looked up, so a handle given out again finds none.
  function textBytes(inout this, cell: u32, lengthOut: usize): usize {
    if (this.runtime.heap.lentDead.length > 0) this.dropDeadText();
    if ((this.textCount + 1) * 2 > this.textCells.length) this.rebuildText(this.textCells.length < 8 ? 8 : this.textCells.length * 2);
    const place = this.textPlace(cell);
    if (this.textCells[place] != cell) {
      const bytes = this.runtime.heap.stringUtf8(cell);
      const buffer = nativeAlloc(bytes.length + 1);
      let index: usize = 0;
      while (index < bytes.length) {
        nativeStoreByte(buffer, index, bytes[index]);
        index = index + 1;
      }
      nativeStoreByte(buffer, bytes.length, 0);
      this.textCells[place] = cell;
      this.textBuffers[place] = buffer;
      this.textLengths[place] = bytes.length;
      this.textCount = this.textCount + 1;
      this.runtime.heap.lendString(cell);
    }
    nativeStoreLength(lengthOut, this.textLengths[place]);
    return this.textBuffers[place];
  }

  // Where a cell's copy is, or the free place it would take.
  function textPlace(cell: u32): usize {
    const mask = this.textCells.length - 1;
    let place = usize(cell.wrappingMultiply(2654435761)) & mask;
    while (this.textCells[place] != 0 && this.textCells[place] != cell) {
      place = (place + 1) & mask;
    }
    return place;
  }

  // The table again with `capacity` places, a power of two, without the
  // copies that were freed (a buffer of 0).
  function rebuildText(inout this, capacity: usize): void {
    let cells = Array<u32>();
    let buffers = Array<usize>();
    let lengths = Array<usize>();
    cells.appendRepeated(0, capacity);
    buffers.appendRepeated(0, capacity);
    lengths.appendRepeated(0, capacity);
    const oldCells = replace(inout this.textCells, move cells);
    const oldBuffers = replace(inout this.textBuffers, move buffers);
    const oldLengths = replace(inout this.textLengths, move lengths);
    this.textCount = 0;
    let index: usize = 0;
    while (index < oldCells.length) {
      if (oldCells[index] != 0 && oldBuffers[index] != 0) {
        const place = this.textPlace(oldCells[index]);
        this.textCells[place] = oldCells[index];
        this.textBuffers[place] = oldBuffers[index];
        this.textLengths[place] = oldLengths[index];
        this.textCount = this.textCount + 1;
      }
      index = index + 1;
    }
  }

  // The copies of the lent strings that have died are freed. A freed
  // one keeps its place until the table is made again, so that the ones
  // that follow it in a run are still found.
  function dropDeadText(inout this): void {
    const dead = replace(inout this.runtime.heap.lentDead, Array<u32>());
    if (this.textCells.length == 0) return;
    let index: usize = 0;
    let dropped = false;
    while (index < dead.length) {
      const place = this.textPlace(dead[index]);
      if (this.textCells[place] == dead[index] && this.textBuffers[place] != 0) {
        nativeFree(this.textBuffers[place]);
        this.textBuffers[place] = 0;
        dropped = true;
      }
      index = index + 1;
    }
    if (dropped) this.rebuildText(this.textCells.length);
  }

  deinit on thread.any {
    let index: usize = 0;
    while (index < this.textCells.length) {
      if (this.textCells[index] != 0 && this.textBuffers[index] != 0) nativeFree(this.textBuffers[index]);
      index = index + 1;
    }
  }

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

function nativeLoadByte(buffer: usize, index: usize): u8 = raw c {
  return ((const uint8_t *)buffer)[index];
}

function nativeFree(buffer: usize): void = raw c {
  free((void *)buffer);
}

// The index-th of the 64-bit words at an address: zjs_call's arguments.
function nativeLoadWord(address: usize, index: usize): u64 = raw c {
  return ((const uint64_t *)address)[index];
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

// --- Values across the ABI ---
//
// A ZjsValue has the engine's own bits for a number, a boolean, null,
// and undefined. A cell crosses with two things packed above its handle,
// inside the 48 bits zjs.h gives a cell: the slot of the context whose
// heap it is in (zjs_string_bytes and zjs_array_length are given no
// context), and its kind (the header's cell predicates are tests of
// those bits in the shim, with no call into the engine). Coming back in
// both are taken off; a cell of another context, a handle outside the
// heap's table, and the engine's own markers come in as undefined (a
// handle whose cell has died is not known from a live one: zjs.h makes
// the embedder keep what it uses alive). A slot
// past ABI_SLOT_LIMIT crosses as 0: such a context's cells are refused
// by the two calls that are given no context.

const ABI_HANDLE_MASK: u64 = 0x3_FFFF_FFFF;
const ABI_SLOT_SHIFT: u64 = 34;
const ABI_SLOT_LIMIT: u32 = 2047;
const ABI_KIND_SHIFT: u64 = 45;
const ABI_KIND_STRING: u64 = 1;
const ABI_KIND_OBJECT: u64 = 2;
const ABI_KIND_ARRAY: u64 = 3;
const ABI_KIND_FUNCTION: u64 = 4;
const ABI_KIND_HOST_FUNCTION: u64 = 5;

function exportValue(in runtime: Runtime, slot: u32, value: Value): u64 {
  if (!isCell(value)) {
    if (isDeleted(value) || isHole(value)) return VALUE_UNDEFINED;
    return value.bits;
  }
  const cell = asCell(value);
  if (cell == 0) return VALUE_UNDEFINED;
  const tag = runtime.heap.tagOf(cell);
  let kind: u64 = 0;
  if (tag == TAG_STRING) {
    kind = ABI_KIND_STRING;
  } else if (tag == TAG_OBJECT || tag == TAG_PROMISE || tag == TAG_REGEXP) {
    kind = ABI_KIND_OBJECT;
  } else if (tag == TAG_ARRAY) {
    kind = ABI_KIND_ARRAY;
  } else if (tag == TAG_FUNCTION || tag == TAG_CLOSURE) {
    kind = ABI_KIND_FUNCTION;
  } else if (tag == TAG_HOST_FUNCTION) {
    kind = ABI_KIND_HOST_FUNCTION;
  }
  const field: u64 = slot <= ABI_SLOT_LIMIT ? u64(slot) : 0;
  return value.bits | (field << ABI_SLOT_SHIFT) | (kind << ABI_KIND_SHIFT);
}

function importValue(in runtime: Runtime, slot: u32, bits: u64): Value {
  const value = Value({ bits: bits });
  if (!isCell(value)) {
    if (isNumber(value) || bits == VALUE_NULL || bits == VALUE_FALSE || bits == VALUE_TRUE) return value;
    return undefinedValue();
  }
  const field = u32((bits >> ABI_SLOT_SHIFT) & u64(ABI_SLOT_LIMIT));
  if (field != 0 && field != slot) return undefinedValue();
  const cell = u32((bits & ABI_HANDLE_MASK) >> 2);
  if (!runtime.heap.handleInTable(cell)) return undefinedValue();
  return cellValue(cell);
}

// The context in a slot, whatever its generation: for the two calls that
// are given a value and no context. A value outlives its context only by
// the embedder's mistake, and then names whatever has the slot now.
function retainSlot(slot: u32): Option<Context> {
  if (slot == 0) return Option<Context>.none;
  const current = engine.get();
  return current.registry.withLock((in registry): Option<Context> => {
    const at = usize(slot - 1);
    if (at >= registry.slots.length) return Option<Context>.none;
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

// What the last evaluation produced (zjs_eval and the others return it):
// undefined when it threw.
export c function zjs_z_result(handle: usize): u64 {
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): u64 => {
        if (state.hadError) return VALUE_UNDEFINED;
        return exportValue(in state.runtime, slot, state.lastResult);
      });
    }
    none => {
      return VALUE_UNDEFINED;
    }
  }
}

// What the last evaluation threw (zjs_get_error): undefined when it did
// not throw.
export c function zjs_z_error(handle: usize): u64 {
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): u64 => {
        if (!state.hadError) return VALUE_UNDEFINED;
        return exportValue(in state.runtime, slot, state.lastResult);
      });
    }
    none => {
      return VALUE_UNDEFINED;
    }
  }
}

// zjs_new_string: the one string cell with this UTF-8 text.
export c function zjs_z_new_string(handle: usize, text: Slice<u8>): u64 {
  const bytes = sliceToBytes(text);
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((inout state): u64 => {
        const byteCount = bytes.length;
        const cell = state.runtime.internUtf8(sliceBytes(in bytes, 0, byteCount));
        return exportValue(in state.runtime, slot, cellValue(cell));
      });
    }
    none => {
      return VALUE_UNDEFINED;
    }
  }
}

// zjs_string_bytes: 0 for what is not a string of the context in `slot`.
export c function zjs_z_string_bytes(slot: u32, bits: u64, lengthOut: usize): usize {
  const found = retainSlot(slot);
  match (found) {
    some(context) => {
      return context.state.withLock((inout state): usize => {
        const value = importValue(in state.runtime, slot, bits);
        if (!isCell(value) || !state.runtime.heap.isString(asCell(value))) return 0;
        return state.textBytes(asCell(value), lengthOut);
      });
    }
    none => {
      return 0;
    }
  }
}

export c function zjs_z_new_object(handle: usize): u64 {
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((inout state): u64 => {
        const proto = state.runtime.objectProto;
        const made = state.runtime.heap.allocateObject(proto);
        return exportValue(in state.runtime, slot, cellValue(made));
      });
    }
    none => {
      return VALUE_UNDEFINED;
    }
  }
}

// zjs_new_array: `length` elements, each undefined.
export c function zjs_z_new_array(handle: usize, length: u32): u64 {
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((inout state): u64 => {
        const made = state.runtime.heap.allocateArray(length);
        let index: u32 = 0;
        while (index < length) {
          state.runtime.heap.arraySet(made, index, undefinedValue());
          index = index + 1;
        }
        return exportValue(in state.runtime, slot, cellValue(made));
      });
    }
    none => {
      return VALUE_UNDEFINED;
    }
  }
}

// zjs_array_length: 0 for what is not an array of the context in `slot`.
export c function zjs_z_array_length(slot: u32, bits: u64): u32 {
  const found = retainSlot(slot);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): u32 => {
        const value = importValue(in state.runtime, slot, bits);
        if (!isCell(value) || !state.runtime.heap.isArray(asCell(value))) return 0;
        return state.runtime.heap.arrayLength(asCell(value));
      });
    }
    none => {
      return 0;
    }
  }
}

// zjs_pin, zjs_unpin, zjs_pin_replace: a stack of values the collector
// starts from. Replacing with nothing pinned pins.
export c function zjs_z_pin(handle: usize, bits: u64): void {
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        const value = importValue(in state.runtime, slot, bits);
        state.runtime.hostPins.push(value);
      });
    }
    none => {
    }
  }
}

export c function zjs_z_unpin(handle: usize): void {
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        const dropped = state.runtime.hostPins.pop();
      });
    }
    none => {
    }
  }
}

export c function zjs_z_pin_replace(handle: usize, bits: u64): void {
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        const value = importValue(in state.runtime, slot, bits);
        const held = state.runtime.hostPins.length;
        if (held == 0) {
          state.runtime.hostPins.push(value);
        } else {
          state.runtime.hostPins[held - 1] = value;
        }
      });
    }
    none => {
    }
  }
}

// zjs_root: a place in the table of roots, as its index plus one (0 is
// no root); zjs_unroot gives the place back, and zjs_root_get reads it,
// undefined for a place that holds nothing.
export c function zjs_z_root(handle: usize, bits: u64): u32 {
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((inout state): u32 => {
        const value = importValue(in state.runtime, slot, bits);
        match (state.runtime.hostRootsFree.pop()) {
          some(place) => {
            state.runtime.hostRoots[usize(place)] = value;
            return place + 1;
          }
          none => {
            state.runtime.hostRoots.push(value);
            return u32(state.runtime.hostRoots.length);
          }
        }
      });
    }
    none => {
      return 0;
    }
  }
}

export c function zjs_z_unroot(handle: usize, root: u32): void {
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        if (root == 0 || usize(root) > state.runtime.hostRoots.length) return;
        const at = usize(root - 1);
        if (isDeleted(state.runtime.hostRoots[at])) return;
        state.runtime.hostRoots[at] = deletedValue();
        state.runtime.hostRootsFree.push(root - 1);
      });
    }
    none => {
    }
  }
}

export c function zjs_z_root_get(handle: usize, root: u32): u64 {
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): u64 => {
        if (root == 0 || usize(root) > state.runtime.hostRoots.length) return VALUE_UNDEFINED;
        return exportValue(in state.runtime, slot, state.runtime.hostRoots[usize(root - 1)]);
      });
    }
    none => {
      return VALUE_UNDEFINED;
    }
  }
}

// --- Properties, globals, and calls ---
//
// Each may run JavaScript (a getter, a setter, the function called). A
// throw is the context's error, as an evaluation's is, and the call
// answers undefined. zjs_call runs the jobs the function queued before it
// returns; a property read or write leaves any its accessor queued for
// zjs_drain_microtasks or the next call or evaluation.

// A property key from the embedder's bytes: the string's atom.
function keyOf(inout runtime: Runtime, in name: Array<u8>): Value {
  const count = name.length;
  return cellValue(runtime.internUtf8(sliceBytes(in name, 0, count)));
}

// A property of null or undefined is a TypeError, raised here as the
// interpreter raises it for `obj.name`: getProperty and setProperty
// answer such an object quietly. True when it was raised.
function refuseNullish(inout runtime: Runtime, target: Value, key: Value, reading: boolean): boolean {
  if (!isNull(target) && !isUndefined(target)) return false;
  const atom = runtime.propertyKey(key);
  const error = runtime.propertyOfNullish(target, atom, reading);
  runtime.raise(error);
  return true;
}

// An element's key: the index as the number a program would write.
function indexKey(index: u32): Value {
  if (index <= 2147483647) return int32Value(i32(index));
  return doubleValue(f64(index));
}

export c function zjs_z_get_property(handle: usize, object: u64, name: Slice<u8>): u64 {
  const bytes = sliceToBytes(name);
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((inout state): u64 => {
        const target = importValue(in state.runtime, slot, object);
        const key = keyOf(inout state.runtime, in bytes);
        let value = undefinedValue();
        if (!refuseNullish(inout state.runtime, target, key, true)) value = state.runtime.getProperty(target, key);
        if (!state.settle()) return VALUE_UNDEFINED;
        return exportValue(in state.runtime, slot, value);
      });
    }
    none => {
      return VALUE_UNDEFINED;
    }
  }
}

export c function zjs_z_set_property(handle: usize, object: u64, name: Slice<u8>, value: u64): void {
  const bytes = sliceToBytes(name);
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        const target = importValue(in state.runtime, slot, object);
        const stored = importValue(in state.runtime, slot, value);
        const key = keyOf(inout state.runtime, in bytes);
        if (!refuseNullish(inout state.runtime, target, key, false)) {
          const accepted = state.runtime.setProperty(target, key, stored);
        }
        const settled = state.settle();
      });
    }
    none => {
    }
  }
}

export c function zjs_z_get_element(handle: usize, object: u64, index: u32): u64 {
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((inout state): u64 => {
        const target = importValue(in state.runtime, slot, object);
        const key = indexKey(index);
        let value = undefinedValue();
        if (!refuseNullish(inout state.runtime, target, key, true)) value = state.runtime.getProperty(target, key);
        if (!state.settle()) return VALUE_UNDEFINED;
        return exportValue(in state.runtime, slot, value);
      });
    }
    none => {
      return VALUE_UNDEFINED;
    }
  }
}

export c function zjs_z_set_element(handle: usize, object: u64, index: u32, value: u64): void {
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        const target = importValue(in state.runtime, slot, object);
        const stored = importValue(in state.runtime, slot, value);
        const key = indexKey(index);
        if (!refuseNullish(inout state.runtime, target, key, false)) {
          const accepted = state.runtime.setProperty(target, key, stored);
        }
        const settled = state.settle();
      });
    }
    none => {
    }
  }
}

// zjs_get_global, zjs_set_global: a property of the global object, which
// a script's var and function declarations are, and which a name no
// script declared becomes when it is set.
export c function zjs_z_get_global(handle: usize, name: Slice<u8>): u64 {
  const bytes = sliceToBytes(name);
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((inout state): u64 => {
        const key = keyOf(inout state.runtime, in bytes);
        const global = cellValue(state.runtime.globalObject);
        const value = state.runtime.getProperty(global, key);
        if (!state.settle()) return VALUE_UNDEFINED;
        return exportValue(in state.runtime, slot, value);
      });
    }
    none => {
      return VALUE_UNDEFINED;
    }
  }
}

export c function zjs_z_set_global(handle: usize, name: Slice<u8>, value: u64): void {
  const bytes = sliceToBytes(name);
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        const stored = importValue(in state.runtime, slot, value);
        const key = keyOf(inout state.runtime, in bytes);
        const global = cellValue(state.runtime.globalObject);
        const accepted = state.runtime.setProperty(global, key, stored);
        const settled = state.settle();
      });
    }
    none => {
    }
  }
}

// zjs_call: `argc` values at the address `argv`. Its result is the
// context's (zjs_z_result, zjs_z_error), as an evaluation's is.
export c function zjs_z_call(handle: usize, callee: u64, thisValue: u64, argv: usize, argc: u32): void {
  const slot = handleIndex(handle);
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        let args = Array<Value>();
        let index: u32 = 0;
        while (index < argc) {
          args.push(importValue(in state.runtime, slot, nativeLoadWord(argv, usize(index))));
          index = index + 1;
        }
        const target = importValue(in state.runtime, slot, callee);
        const receiver = importValue(in state.runtime, slot, thisValue);
        state.call(target, receiver, move args);
      });
    }
    none => {
    }
  }
}

// zjs_drain_microtasks: the queued jobs, run now.
export c function zjs_z_drain_microtasks(handle: usize): void {
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        state.runtime.runJobs();
        const settled = state.settle();
      });
    }
    none => {
    }
  }
}

// zjs_has_pending_work: 1 while a job is queued. There are no timers.
export c function zjs_z_has_pending_work(handle: usize): i32 {
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): i32 => state.runtime.jobCursor < state.runtime.jobEnd ? 1 : 0);
    }
    none => {
      return 0;
    }
  }
}

// zjs_gc: a whole collection now.
export c function zjs_z_gc(handle: usize): void {
  const found = retain(handle);
  match (found) {
    some(context) => {
      context.state.withLock((inout state): void => {
        state.runtime.collectAll();
      });
    }
    none => {
    }
  }
}

// The collector's figures since the context was made: collections of
// every kind, the sum of their pauses and the longest in nanoseconds,
// and the cells given back.
export c function zjs_z_gc_collections(handle: usize): u32 {
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): u32 => state.runtime.heap.collections);
    }
    none => {
      return 0;
    }
  }
}

export c function zjs_z_gc_pause_total(handle: usize): u64 {
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): u64 => u64(state.runtime.gcPauseTotal));
    }
    none => {
      return 0;
    }
  }
}

export c function zjs_z_gc_pause_max(handle: usize): u64 {
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): u64 => u64(state.runtime.gcPauseMax));
    }
    none => {
      return 0;
    }
  }
}

export c function zjs_z_gc_cells_freed(handle: usize): u32 {
  const found = retain(handle);
  match (found) {
    some(context) => {
      return context.state.withLock((in state): u32 => {
        const made = state.runtime.heap.cellsAllocated();
        const live = f64(state.runtime.heap.liveCells());
        return made > live ? u32(made - live) : 0;
      });
    }
    none => {
      return 0;
    }
  }
}

// Live heap cells in a context (zjs_cell_count).
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
