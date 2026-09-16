// The regular-expression backend boundary on the Z side. The matcher is
// libregexp behind native/zjs_regexp.h; this module owns the cache of
// compiled patterns (by source and flags), copies patterns (UTF-8) and
// inputs (the heap's Latin-1 or UTF-16 storage) into a buffer the
// backend owns, and hands back code-unit offsets and codes. Nothing else
// in the engine names the backend.
import native from "./native/zjs_regexp.h";
import { bytesOf } from "./heap.zs";
import { expect } from "std/test";

// Flag bits, the RegExp letters d g i m s u y v.
export const REGEX_GLOBAL: i32 = 1;
export const REGEX_IGNORE_CASE: i32 = 2;
export const REGEX_MULTILINE: i32 = 4;
export const REGEX_DOT_ALL: i32 = 8;
export const REGEX_UNICODE: i32 = 16;
export const REGEX_STICKY: i32 = 32;
export const REGEX_HAS_INDICES: i32 = 64;
export const REGEX_UNICODE_SETS: i32 = 256;

// Exec results.
export const REGEX_MATCH: i32 = 1;
export const REGEX_NO_MATCH: i32 = 0;
export const REGEX_OUT_OF_MEMORY: i32 = -1;
export const REGEX_STEP_LIMIT: i32 = -2;
export const REGEX_BAD_BYTECODE: i32 = -3;
export const REGEX_STACK_LIMIT: i32 = -4;
export const REGEX_SYNTAX: i32 = -5;

const CACHE_LIMIT: usize = 256;

export struct RegexEntry {
  source: Array<u8>;
  flags: i32;
  handle: usize;
  captures: i32;
  hasNames: boolean;
  names: Array<u8>;
  lastUse: u64;
  generation: f64;
}

function copyBytes(in bytes: Array<u8>): Array<u8> {
  let copy = Array<u8>();
  let i: usize = 0;
  while (i < bytes.length) {
    copy.push(bytes[i]);
    i = i + 1;
  }
  return copy;
}

// The context's scratch buffer holding a copy of the bytes; zero when
// memory is out.
function loadBuffer(context: usize, in bytes: Array<u8>): usize {
  const buffer = native.zjs_re_scratch(context, bytes.length);
  if (buffer == 0) return 0;
  let i: usize = 0;
  while (i < bytes.length) {
    native.zjs_re_buffer_store(buffer, i, bytes[i]);
    i = i + 1;
  }
  return buffer;
}

export struct RegexBackend {
  // The native context: scratch, captures, limits, and accounting, owned
  // here and released with `release`.
  context: usize;
  entries: Array<RegexEntry>;
  clock: u64;
  generations: f64;
  lastError: Array<u8>;
  // The category of the last compile failure: a REGEX_* code.
  lastFailure: i32;

  // Whether slot `i` holds this pattern (compared in place: an array
  // element's field cannot be lent out).
  function slotHolds(i: usize, in source: Array<u8>, flags: i32): boolean {
    if (this.entries[i].flags != flags) return false;
    if (this.entries[i].source.length != source.length) return false;
    let k: usize = 0;
    while (k < source.length) {
      if (this.entries[i].source[k] != source[k]) return false;
      k = k + 1;
    }
    return true;
  }

  // The cache slot holding this pattern, or -1.
  function lookup(in source: Array<u8>, flags: i32): i32 {
    let i: usize = 0;
    while (i < this.entries.length) {
      if (this.slotHolds(i, in source, flags)) return i32(i);
      i = i + 1;
    }
    return -1;
  }

  function entryMatches(entry: i32, in source: Array<u8>, flags: i32): boolean {
    if (entry < 0 || usize(entry) >= this.entries.length) return false;
    return this.slotHolds(usize(entry), in source, flags);
  }

  // Compile, or find compiled; the cache slot, or -1 with `lastFailure`
  // holding the category and, for a syntax failure, `lastError` the
  // backend's message.
  function compile(inout this, in source: Array<u8>, flags: i32): i32 {
    const found = this.lookup(in source, flags);
    if (found >= 0) {
      this.clock = this.clock + 1;
      this.entries[usize(found)].lastUse = this.clock;
      return found;
    }
    const context = this.context;
    const buffer = loadBuffer(context, in source);
    if (buffer == 0) {
      this.lastFailure = REGEX_OUT_OF_MEMORY;
      this.lastError = Array<u8>();
      return -1;
    }
    const handle = native.zjs_re_compile(context, buffer, source.length, flags);
    if (handle == 0) {
      this.lastFailure = native.zjs_re_failure(context);
      let message = Array<u8>();
      let index: i32 = 0;
      while (index < 128) {
        const byte = native.zjs_re_error_byte(context, index);
        if (byte < 0) break;
        message.push(u8(byte));
        index = index + 1;
      }
      this.lastError = move message;
      return -1;
    }
    this.lastFailure = 0;
    let names = Array<u8>();
    const hasNames = native.zjs_re_has_names(handle) != 0;
    if (hasNames) {
      let index: i32 = 0;
      while (true) {
        const byte = native.zjs_re_name_byte(handle, index);
        if (byte < 0) break;
        names.push(u8(byte));
        index = index + 1;
      }
    }
    this.generations = this.generations + 1.0;
    const entry = RegexEntry({
      source: copyBytes(in source), flags: flags, handle: handle,
      captures: native.zjs_re_capture_count(handle), hasNames: hasNames, names: move names, lastUse: this.clock + 1,
      generation: this.generations,
    });
    this.clock = this.clock + 1;
    if (this.entries.length < CACHE_LIMIT) {
      this.entries.push(move entry);
      return i32(this.entries.length - 1);
    }
    // Full: the least recently used slot is reused.
    let victim: usize = 0;
    let i: usize = 1;
    while (i < this.entries.length) {
      if (this.entries[i].lastUse < this.entries[victim].lastUse) victim = i;
      i = i + 1;
    }
    native.zjs_re_free(this.entries[victim].handle);
    this.entries[victim] = move entry;
    return i32(victim);
  }

  // A copy of the last compile failure's message.
  function errorMessage(): Array<u8> {
    let copy = Array<u8>();
    let k: usize = 0;
    while (k < this.lastError.length) {
      copy.push(this.lastError[k]);
      k = k + 1;
    }
    return copy;
  }

  // A slot's ticket: changes whenever the slot is filled anew, so a
  // holder can tell its compiled form is still the one it cached. Zero
  // for no slot.
  function ticket(entry: i32): f64 {
    if (entry < 0 || usize(entry) >= this.entries.length) return 0.0;
    return this.entries[usize(entry)].generation;
  }

  function captures(entry: i32): i32 {
    return this.entries[usize(entry)].captures;
  }

  function hasNames(entry: i32): boolean {
    return this.entries[usize(entry)].hasNames;
  }

  // The NUL-separated group names, in capture order from group 1.
  function names(entry: i32): Array<u8> {
    let copy = Array<u8>();
    let k: usize = 0;
    while (k < this.entries[usize(entry)].names.length) {
      copy.push(this.entries[usize(entry)].names[k]);
      k = k + 1;
    }
    return copy;
  }

  // The scratch buffer for an input of `length` bytes, to fill with
  // `store` before `execLoaded`; zero when memory is out.
  function reserve(length: usize): usize {
    return native.zjs_re_scratch(this.context, length);
  }

  function store(buffer: usize, index: usize, byte: u8): void {
    native.zjs_re_buffer_store(buffer, index, byte);
  }

  // Run a compiled pattern over the loaded buffer -- `length` units, one
  // byte each or two when `wide` -- from a unit offset; a REGEX_* code.
  // The captures are readable until the next exec.
  function execLoaded(inout this, entry: i32, buffer: usize, length: usize, start: usize, wide: boolean): i32 {
    const handle = this.entries[usize(entry)].handle;
    const result = native.zjs_re_exec(this.context, handle, buffer, length, start, wide ? 1 : 0);
    this.clock = this.clock + 1;
    this.entries[usize(entry)].lastUse = this.clock;
    return result;
  }

  function captureStart(group: i32): i32 {
    return native.zjs_re_capture_start(this.context, group);
  }

  function captureEnd(group: i32): i32 {
    return native.zjs_re_capture_end(this.context, group);
  }

  // Free every compiled pattern and the native context (teardown).
  function release(inout this): void {
    let i: usize = 0;
    while (i < this.entries.length) {
      native.zjs_re_free(this.entries[i].handle);
      i = i + 1;
    }
    this.entries = Array<RegexEntry>();
    if (this.context != 0) native.zjs_re_context_free(this.context);
    this.context = 0;
  }

  function liveHandles(): usize {
    return native.zjs_re_live_handles(this.context);
  }

  function liveBytes(): usize {
    return native.zjs_re_live_bytes(this.context);
  }

  // Scratch, transcoding, and capture memory the context keeps between
  // calls.
  function retainedBytes(): usize {
    return native.zjs_re_retained_bytes(this.context);
  }

  function setStackBudget(bytes: usize): void {
    native.zjs_re_set_stack_budget(this.context, bytes);
  }

  function setStepBudget(checks: usize): void {
    native.zjs_re_set_step_budget(this.context, checks);
  }

  // Deterministic out-of-memory coverage: the Nth allocation through the
  // context fails (zero for none).
  function setAllocationLimit(count: usize): void {
    native.zjs_re_set_allocation_limit(this.context, count);
  }

  function allocationCount(): usize {
    return native.zjs_re_allocation_count(this.context);
  }
}

export function createRegexBackend(): RegexBackend {
  return RegexBackend({ context: native.zjs_re_context_new(), entries: Array<RegexEntry>(), clock: 0, generations: 0.0, lastError: Array<u8>(), lastFailure: 0 });
}

function asciiBytes(in text: String): Array<u8> {
  return bytesOf(in text);
}

test "two backends keep independent captures, scratch, and accounting" {
  let first = createRegexBackend();
  let second = createRegexBackend();
  const patternA: String = "(b+)c";
  const patternB: String = "x(y)?z";
  const sourceA = asciiBytes(in patternA);
  const sourceB = asciiBytes(in patternB);
  const entryA = first.compile(in sourceA, 0);
  const entryB = second.compile(in sourceB, 0);
  expect(entryA >= 0).toEqual(true);
  expect(entryB >= 0).toEqual(true);
  expect(first.liveHandles()).toEqual(1);
  expect(second.liveHandles()).toEqual(1);
  const inputA: String = "abbbcd";
  const inputB: String = "..xz..";
  const bytesA = asciiBytes(in inputA);
  const bytesB = asciiBytes(in inputB);
  const bufferA = first.reserve(bytesA.length);
  let i: usize = 0;
  while (i < bytesA.length) { first.store(bufferA, i, bytesA[i]); i = i + 1; }
  expect(first.execLoaded(entryA, bufferA, bytesA.length, 0, false)).toEqual(REGEX_MATCH);
  // The second context's exec must not disturb the first's captures.
  const bufferB = second.reserve(bytesB.length);
  i = 0;
  while (i < bytesB.length) { second.store(bufferB, i, bytesB[i]); i = i + 1; }
  expect(second.execLoaded(entryB, bufferB, bytesB.length, 0, false)).toEqual(REGEX_MATCH);
  expect(first.captureStart(0)).toEqual(1);
  expect(first.captureEnd(0)).toEqual(5);
  expect(first.captureStart(1)).toEqual(1);
  expect(first.captureEnd(1)).toEqual(4);
  expect(second.captureStart(0)).toEqual(2);
  expect(second.captureEnd(0)).toEqual(4);
  expect(second.captureStart(1)).toEqual(-1);
  expect(first.retainedBytes() > 0).toEqual(true);
  // A syntax failure and a limit failure are told apart.
  const bad: String = "(";
  const badBytes = asciiBytes(in bad);
  expect(first.compile(in badBytes, 0)).toEqual(-1);
  expect(first.lastFailure).toEqual(REGEX_SYNTAX);
  expect(first.lastError.length > 0).toEqual(true);
  second.setStackBudget(1);
  const deep: String = "((((a))))";
  const deepBytes = asciiBytes(in deep);
  expect(second.compile(in deepBytes, 0)).toEqual(-1);
  expect(second.lastFailure).toEqual(REGEX_STACK_LIMIT);
  first.release();
  second.release();
  expect(first.context).toEqual(0);
}

test "resource failures carry their category: memory, steps, stack" {
  let backend = createRegexBackend();
  const pattern: String = "(a|b)*c";
  const source = asciiBytes(in pattern);
  // Compile: the first allocation refused is out of memory, not syntax,
  // whatever message the parser writes.
  backend.setAllocationLimit(1);
  expect(backend.compile(in source, 0)).toEqual(-1);
  expect(backend.lastFailure).toEqual(REGEX_OUT_OF_MEMORY);
  backend.setAllocationLimit(0);
  const entry = backend.compile(in source, 0);
  expect(entry >= 0).toEqual(true);
  const before = backend.allocationCount();
  // Exec: backtracking state is allocated through the context; refuse it.
  let input = Array<u8>();
  let i: usize = 0;
  while (i < 2000) { input.push(97); i = i + 1; }
  input.push(99);
  const buffer = backend.reserve(input.length);
  i = 0;
  while (i < input.length) { backend.store(buffer, i, input[i]); i = i + 1; }
  expect(backend.execLoaded(entry, buffer, input.length, 0, false)).toEqual(REGEX_MATCH);
  expect(backend.allocationCount() > before).toEqual(true);
  backend.setAllocationLimit(1);
  expect(backend.execLoaded(entry, buffer, input.length, 0, false)).toEqual(REGEX_OUT_OF_MEMORY);
  backend.setAllocationLimit(0);
  // Steps: a catastrophic pattern under a budget of one check.
  const slow: String = "(a+)+$";
  const slowSource = asciiBytes(in slow);
  const slowEntry = backend.compile(in slowSource, 0);
  expect(slowEntry >= 0).toEqual(true);
  let hard = Array<u8>();
  i = 0;
  while (i < 40) { hard.push(97); i = i + 1; }
  hard.push(98);
  const hardBuffer = backend.reserve(hard.length);
  i = 0;
  while (i < hard.length) { backend.store(hardBuffer, i, hard[i]); i = i + 1; }
  backend.setStepBudget(1);
  expect(backend.execLoaded(slowEntry, hardBuffer, hard.length, 0, false)).toEqual(REGEX_STEP_LIMIT);
  backend.setStepBudget(0);
  // Stack: the compiler's recursion under a one-byte budget.
  backend.setStackBudget(1);
  const deep: String = "((a))";
  const deepSource = asciiBytes(in deep);
  expect(backend.compile(in deepSource, 0)).toEqual(-1);
  expect(backend.lastFailure).toEqual(REGEX_STACK_LIMIT);
  backend.release();
}
