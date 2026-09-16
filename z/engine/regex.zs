// The regular-expression backend boundary on the Z side. The matcher is
// libregexp behind native/zjs_regexp.h; this module owns the cache of
// compiled patterns (by source and flags), copies patterns and inputs
// into buffers the backend owns, and hands back byte offsets and codes.
// Nothing else in the engine names the backend.
import native from "./native/zjs_regexp.h";
import { bytesOf } from "./heap.zs";

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

// The backend's scratch buffer holding a copy of the bytes; zero when
// memory is out.
function loadBuffer(in bytes: Array<u8>): usize {
  const buffer = native.zjs_re_scratch(bytes.length);
  if (buffer == 0) return 0;
  let i: usize = 0;
  while (i < bytes.length) {
    native.zjs_re_buffer_store(buffer, i, bytes[i]);
    i = i + 1;
  }
  return buffer;
}

export struct RegexBackend {
  entries: Array<RegexEntry>;
  clock: u64;
  generations: f64;
  lastError: Array<u8>;

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

  // Compile, or find compiled; the cache slot, or -1 with `lastError`
  // holding the backend's message.
  function compile(inout this, in source: Array<u8>, flags: i32): i32 {
    const found = this.lookup(in source, flags);
    if (found >= 0) {
      this.clock = this.clock + 1;
      this.entries[usize(found)].lastUse = this.clock;
      return found;
    }
    const buffer = loadBuffer(in source);
    if (buffer == 0) {
      const message: String = "out of memory";
      this.lastError = bytesOf(in message);
      return -1;
    }
    const handle = native.zjs_re_compile(buffer, source.length, flags);
    if (handle == 0) {
      let message = Array<u8>();
      let index: i32 = 0;
      while (index < 128) {
        const byte = native.zjs_re_error_byte(index);
        if (byte < 0) break;
        message.push(u8(byte));
        index = index + 1;
      }
      this.lastError = move message;
      return -1;
    }
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
    return native.zjs_re_scratch(length);
  }

  function store(buffer: usize, index: usize, byte: u8): void {
    native.zjs_re_buffer_store(buffer, index, byte);
  }

  // Run a compiled pattern over the loaded buffer from a byte offset; a
  // REGEX_* code. The captures are readable until the next exec.
  function execLoaded(inout this, entry: i32, buffer: usize, length: usize, start: usize): i32 {
    const handle = this.entries[usize(entry)].handle;
    const result = native.zjs_re_exec(handle, buffer, length, start);
    this.clock = this.clock + 1;
    this.entries[usize(entry)].lastUse = this.clock;
    return result;
  }

  function captureStart(group: i32): i32 {
    return native.zjs_re_capture_start(group);
  }

  function captureEnd(group: i32): i32 {
    return native.zjs_re_capture_end(group);
  }

  // Free every compiled pattern (context teardown).
  function release(inout this): void {
    let i: usize = 0;
    while (i < this.entries.length) {
      native.zjs_re_free(this.entries[i].handle);
      i = i + 1;
    }
    this.entries = Array<RegexEntry>();
  }

  function liveHandles(): usize {
    return native.zjs_re_live_handles();
  }

  function liveBytes(): usize {
    return native.zjs_re_live_bytes();
  }
}

export function createRegexBackend(): RegexBackend {
  return RegexBackend({ entries: Array<RegexEntry>(), clock: 0, generations: 0.0, lastError: Array<u8>() });
}

// Limits, for the embedder: the matcher's recursion budget in bytes and
// an optional per-exec step budget (zero for none).
export function setRegexStackBudget(bytes: usize): void {
  native.zjs_re_set_stack_budget(bytes);
}

export function setRegexStepBudget(checks: usize): void {
  native.zjs_re_set_step_budget(checks);
}
