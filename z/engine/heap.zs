// Handle-based cell heap.
//
// The Phase 0 spike measured this against a malloc/raw-pointer heap: it costs
// roughly 5% on a dispatch-heavy microbenchmark, and buys a great deal. No raw
// pointer touches the object graph, so the GC will operate over Z-owned values
// with ownership intact; handles are position-independent, which makes the
// mmap-ready zero-copy AOT bundle nearly free; and it is trivially
// cross-platform. See z/spike/RESULTS.md.
//
// Layout is two parallel arrays rather than one packed slab:
//
//   headers[handle]  -> tag, mark bit, and the cell's slot range
//   slots[start..]   -> the cell's payload words, contiguous
//
// A handle indexes `headers`. Handle 0 is reserved and never allocated, so a
// live cell handle is always >= 1 and `cellValue(0)` can mean "no cell".
//
// Collection is mark-sweep with stable handles. Marking walks from the
// roots the runtime supplies; sweeping frees dead headers onto a free list
// for reuse and compacts every live cell's slots into a fresh arena, so an
// object that outgrew its range leaves no permanent hole. Nothing outside
// the heap has to be updated: a handle never changes, only the slot range
// behind it.

import { expect } from "std/test";
import { Value, undefinedValue, deletedValue, isDeleted, cellValue, asCell, isCell, int32Value, asInt32 } from "./value.zs";

// Tags mirror the reference engine (src/value.zc) so the two implementations
// stay legible against each other during the migration.
export const TAG_FUNCTION: u8 = 0;
export const TAG_STRING: u8 = 1;
export const TAG_OBJECT: u8 = 2;
export const TAG_ARRAY: u8 = 3;
export const TAG_HOST_FUNCTION: u8 = 4;
export const TAG_HIDDEN_CLASS: u8 = 5;
export const TAG_CLOSURE: u8 = 6;
export const TAG_ACCESSOR: u8 = 7;
export const TAG_PROMISE: u8 = 8;
export const TAG_REGEXP: u8 = 9;

// Beyond the reference's tags: an environment is its own cell here, where
// the reference keeps captured bindings in a property bag.
export const TAG_ENV: u8 = 200;
// A swept cell whose handle is on the free list.
export const TAG_FREE: u8 = 201;
// Reserved for the unallocatable handle 0.
export const TAG_RESERVED: u8 = 255;

struct CellHeader {
  tag: u8;
  marked: boolean;
  slotStart: u32;
  slotCount: u32;
  // Tag-specific words. `payload`: a string's index into `strings`, a
  // function's index into the runtime's function table, an object's hidden
  // class, an array's length, a host function's builtin id. `link`: a
  // second cell handle -- an object's prototype, a function's `prototype`
  // object, an array's bag of named properties; 0 for none.
  payload: u32;
  link: u32;
}

// A hidden class describes the property layout shared by every object that
// acquired the same names in the same order: `parent` plus one added name
// at slot `transitionSlot`. Lookup walks the parent chain comparing atom
// handles; interned names make that a pointer comparison. Class 0 is the
// empty root. The reference builds a hash table for wide classes; that is a
// performance-phase addition.
struct HiddenClass {
  parent: u32;
  transitionName: u32;
  transitionSlot: u32;
  propCount: u32;
  transitionNames: Array<u32>;
  transitionChildren: Array<u32>;
}

// String cells keep their bytes in a Z-owned Array<u8>, held in a side
// table indexed through the cell header's payload. The reference stores
// plain bytes with a byte length and byte-indexed access -- including
// embedded NULs, which is why the storage is bytes rather than a Z String.
export struct Heap {
  headers: Array<CellHeader>;
  slots: Array<Value>;
  strings: Array<Array<u8>>;
  classes: Array<HiddenClass>;
  // Handles and string-table indices released by a sweep, reused before
  // the arrays grow. `freeHandleCount` / `freeStringCount` mark the live
  // extent, since Z's Array cannot pop.
  freeHandles: Array<u32>;
  freeHandleCount: usize;
  freeStrings: Array<u32>;
  freeStringCount: usize;
  // Marking worklist, reused across collections.
  markStack: Array<u32>;
  markCount: usize;
  // Cells allocated since the last collection, and how many trigger the
  // next one: at least a floor, otherwise proportional to what survived.
  allocatedSinceCollect: u32;
  collectThreshold: u32;
  collections: u32;

  // These are methods rather than free functions for a concrete reason.
  // Z rejects `inout` on a place expression -- `allocate(inout
  // registry.slots[i].heap, ...)` is an error, because an `inout` argument
  // must be a plain mutable binding. A method call on the same projection is
  // accepted, so the heap API has to be methods for the engine to reach a
  // per-context heap at all.
  function allocate(inout this, tag: u8, slotCount: u32): u32 {
    const start = u32(this.slots.length);
    let index: u32 = 0;
    while (index < slotCount) {
      this.slots.push(undefinedValue());
      index = index + 1;
    }
    this.allocatedSinceCollect = this.allocatedSinceCollect + 1;
    const header = CellHeader({
      tag: tag,
      marked: false,
      slotStart: start,
      slotCount: slotCount,
      payload: 0,
      link: 0,
    });
    if (this.freeHandleCount > 0) {
      this.freeHandleCount = this.freeHandleCount - 1;
      const handle = this.freeHandles[this.freeHandleCount];
      this.headers[usize(handle)] = header;
      return handle;
    }
    this.headers.push(header);
    return u32(this.headers.length - 1);
  }

  // Whether enough has been allocated since the last collection for the
  // runtime to collect at its next safe point.
  function shouldCollect(): boolean {
    return this.allocatedSinceCollect >= this.collectThreshold;
  }

  // --- Collection ---
  //
  // The runtime marks its roots with `markValue`, then calls `sweep`.

  function markValue(inout this, value: Value): void {
    if (!isCell(value)) return;
    this.markHandle(asCell(value));
  }

  function markHandle(inout this, handle: u32): void {
    if (handle == 0) return;
    if (this.headers[usize(handle)].marked) return;
    this.headers[usize(handle)].marked = true;
    if (this.markCount < this.markStack.length) {
      this.markStack[this.markCount] = handle;
    } else {
      this.markStack.push(handle);
    }
    this.markCount = this.markCount + 1;
    this.drainMarks();
  }

  // Trace every marked cell's references until the worklist is empty.
  function drainMarks(inout this): void {
    while (this.markCount > 0) {
      this.markCount = this.markCount - 1;
      const handle = this.markStack[this.markCount];
      const tag = this.headers[usize(handle)].tag;
      const link = this.headers[usize(handle)].link;
      if (link != 0 && !this.headers[usize(link)].marked) {
        this.headers[usize(link)].marked = true;
        this.pushMark(link);
      }
      // Slots hold values for every tag but strings and host functions.
      if (tag != TAG_STRING && tag != TAG_HOST_FUNCTION) {
        const start = this.headers[usize(handle)].slotStart;
        const count = this.headers[usize(handle)].slotCount;
        let index: u32 = 0;
        while (index < count) {
          const value = this.slots[usize(start + index)];
          if (isCell(value) && asCell(value) != 0 && !this.headers[usize(asCell(value))].marked) {
            this.headers[usize(asCell(value))].marked = true;
            this.pushMark(asCell(value));
          }
          index = index + 1;
        }
      }
    }
  }

  function pushMark(inout this, handle: u32): void {
    if (this.markCount < this.markStack.length) {
      this.markStack[this.markCount] = handle;
    } else {
      this.markStack.push(handle);
    }
    this.markCount = this.markCount + 1;
  }

  // Free every unmarked cell, compact the live slots into a fresh arena,
  // and clear the marks.
  function sweep(inout this): void {
    let compacted = Array<Value>();
    let survivors: u32 = 0;
    let handle: u32 = 1;
    const count = u32(this.headers.length);
    while (handle < count) {
      const tag = this.headers[usize(handle)].tag;
      if (tag == TAG_FREE) {
        handle = handle + 1;
        continue;
      }
      if (!this.headers[usize(handle)].marked) {
        if (tag == TAG_STRING) {
          const stringIndex = this.headers[usize(handle)].payload;
          this.strings[usize(stringIndex)] = Array<u8>();
          if (this.freeStringCount < this.freeStrings.length) {
            this.freeStrings[this.freeStringCount] = stringIndex;
          } else {
            this.freeStrings.push(stringIndex);
          }
          this.freeStringCount = this.freeStringCount + 1;
        }
        this.headers[usize(handle)] = CellHeader({ tag: TAG_FREE, marked: false, slotStart: 0, slotCount: 0, payload: 0, link: 0 });
        if (this.freeHandleCount < this.freeHandles.length) {
          this.freeHandles[this.freeHandleCount] = handle;
        } else {
          this.freeHandles.push(handle);
        }
        this.freeHandleCount = this.freeHandleCount + 1;
        handle = handle + 1;
        continue;
      }
      survivors = survivors + 1;
      this.headers[usize(handle)].marked = false;
      const start = this.headers[usize(handle)].slotStart;
      const slotCount = this.headers[usize(handle)].slotCount;
      this.headers[usize(handle)].slotStart = u32(compacted.length);
      let index: u32 = 0;
      while (index < slotCount) {
        const kept = this.slots[usize(start + index)];
        compacted.push(kept);
        index = index + 1;
      }
      handle = handle + 1;
    }
    this.slots = move compacted;
    this.allocatedSinceCollect = 0;
    const proportional = survivors * 2;
    this.collectThreshold = proportional > COLLECT_FLOOR ? proportional : COLLECT_FLOOR;
    this.collections = this.collections + 1;
  }

  // Move a cell's slots to a fresh, larger range. The old range is
  // abandoned until the collector compacts.
  function growSlots(inout this, handle: u32, newCount: u32): void {
    const oldStart = this.headers[usize(handle)].slotStart;
    const oldCount = this.headers[usize(handle)].slotCount;
    const start = u32(this.slots.length);
    let index: u32 = 0;
    while (index < oldCount) {
      const kept = this.slots[usize(oldStart + index)];
      this.slots.push(kept);
      index = index + 1;
    }
    while (index < newCount) {
      this.slots.push(undefinedValue());
      index = index + 1;
    }
    this.headers[usize(handle)].slotStart = start;
    this.headers[usize(handle)].slotCount = newCount;
  }

  function linkOf(handle: u32): u32 {
    return this.headers[usize(handle)].link;
  }

  function setLink(inout this, handle: u32, link: u32): void {
    this.headers[usize(handle)].link = link;
  }

  // --- Hidden classes ---

  function classPropCount(classId: u32): u32 {
    return this.classes[usize(classId)].propCount;
  }

  // The slot holding `atom` under `classId`, or -1.
  function classFindSlot(classId: u32, atom: u32): i32 {
    let current = classId;
    while (current != 0) {
      if (this.classes[usize(current)].transitionName == atom) return i32(this.classes[usize(current)].transitionSlot);
      current = this.classes[usize(current)].parent;
    }
    return -1;
  }

  // The class reached by adding `atom` to `classId`, created on first use.
  function classTransition(inout this, classId: u32, atom: u32): u32 {
    const count = this.classes[usize(classId)].transitionNames.length;
    let index: usize = 0;
    while (index < count) {
      if (this.classes[usize(classId)].transitionNames[index] == atom) return this.classes[usize(classId)].transitionChildren[index];
      index = index + 1;
    }
    const propCount = this.classes[usize(classId)].propCount;
    this.classes.push(HiddenClass({
      parent: classId, transitionName: atom, transitionSlot: propCount, propCount: propCount + 1,
      transitionNames: Array<u32>(), transitionChildren: Array<u32>(),
    }));
    const child = u32(this.classes.length - 1);
    this.classes[usize(classId)].transitionNames.push(atom);
    this.classes[usize(classId)].transitionChildren.push(child);
    return child;
  }

  // --- Objects ---

  // An empty object whose prototype is `proto` (0 for none), with room
  // for a few properties before its slots move.
  function allocateObject(inout this, proto: u32): u32 {
    const handle = this.allocate(TAG_OBJECT, 4);
    this.headers[usize(handle)].link = proto;
    return handle;
  }

  function isObject(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_OBJECT;
  }

  function objectClass(handle: u32): u32 {
    return this.headers[usize(handle)].payload;
  }

  function objectProto(handle: u32): u32 {
    return this.headers[usize(handle)].link;
  }

  function setObjectProto(inout this, handle: u32, proto: u32): void {
    this.headers[usize(handle)].link = proto;
  }

  // The object's own slot for `atom`, or -1.
  function objectFindSlot(handle: u32, atom: u32): i32 {
    return this.classFindSlot(this.headers[usize(handle)].payload, atom);
  }

  // Write an own property, adding it (and transitioning the class) when
  // the object does not have it yet.
  function objectSet(inout this, handle: u32, atom: u32, value: Value): void {
    const existing = this.objectFindSlot(handle, atom);
    if (existing >= 0) {
      this.setSlot(handle, u32(existing), value);
      return;
    }
    const parentClass = this.headers[usize(handle)].payload;
    const child = this.classTransition(parentClass, atom);
    const slotIndex = this.classes[usize(child)].transitionSlot;
    if (slotIndex >= this.headers[usize(handle)].slotCount) {
      const grown: u32 = this.headers[usize(handle)].slotCount * 2;
      const needed: u32 = slotIndex + 1;
      this.growSlots(handle, grown > needed ? grown : needed);
    }
    this.headers[usize(handle)].payload = child;
    this.setSlot(handle, slotIndex, value);
  }

  // --- Arrays ---

  // Elements live in the slots; `payload` is the length and the slot count
  // is the capacity. A slot past the length, or holding the deleted
  // marker, is a hole.
  function allocateArray(inout this, length: u32): u32 {
    const capacity: u32 = length < 4 ? 4 : length;
    const handle = this.allocate(TAG_ARRAY, capacity);
    this.headers[usize(handle)].payload = length;
    // Capacity past the length is holes, not undefined.
    let hole = length;
    while (hole < capacity) {
      this.setSlot(handle, hole, deletedValue());
      hole = hole + 1;
    }
    return handle;
  }

  function isArray(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_ARRAY;
  }

  function arrayLength(handle: u32): u32 {
    return this.headers[usize(handle)].payload;
  }

  function arrayHasIndex(handle: u32, index: u32): boolean {
    if (index >= this.headers[usize(handle)].payload) return false;
    if (index >= this.headers[usize(handle)].slotCount) return false;
    return !isDeleted(this.slot(handle, index));
  }

  function arrayGet(handle: u32, index: u32): Value {
    if (!this.arrayHasIndex(handle, index)) return undefinedValue();
    return this.slot(handle, index);
  }

  function arraySet(inout this, handle: u32, index: u32, value: Value): void {
    if (index >= this.headers[usize(handle)].slotCount) {
      let capacity = this.headers[usize(handle)].slotCount;
      while (capacity <= index) { capacity = capacity * 2; }
      const oldCount = this.headers[usize(handle)].slotCount;
      this.growSlots(handle, capacity);
      // Fresh capacity is holes, not undefined.
      let hole = oldCount;
      while (hole < capacity) {
        this.setSlot(handle, hole, deletedValue());
        hole = hole + 1;
      }
    }
    this.setSlot(handle, index, value);
    if (index >= this.headers[usize(handle)].payload) this.headers[usize(handle)].payload = index + 1;
  }

  // Shrinking drops elements; growing exposes holes.
  function setArrayLength(inout this, handle: u32, length: u32): void {
    const old = this.headers[usize(handle)].payload;
    let index = length;
    while (index < old && index < this.headers[usize(handle)].slotCount) {
      this.setSlot(handle, index, deletedValue());
      index = index + 1;
    }
    this.headers[usize(handle)].payload = length;
  }

  // --- Closures and environments ---

  // An environment: one slot per captured binding, `link` the enclosing
  // environment (0 at the outermost).
  function allocateEnv(inout this, parent: u32, slotCount: u32): u32 {
    const handle = this.allocate(TAG_ENV, slotCount);
    this.headers[usize(handle)].link = parent;
    return handle;
  }

  function isEnv(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_ENV;
  }

  // A closure: a function index (`payload`, as for a plain function cell)
  // with the environment it was created in (`link`). Slot 0 holds the
  // `this` an arrow captured; slot 1 its `prototype` object once created.
  function allocateClosure(inout this, functionIndex: u32, env: u32, capturedThis: Value): u32 {
    const handle = this.allocate(TAG_CLOSURE, 2);
    this.headers[usize(handle)].payload = functionIndex;
    this.headers[usize(handle)].link = env;
    this.setSlot(handle, 0, capturedThis);
    return handle;
  }

  function isClosure(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_CLOSURE;
  }

  // --- Host functions ---

  // A builtin implemented in Z; `payload` selects it in the runtime's
  // dispatch, `link` is its `prototype` object once created.
  function allocateHostFunction(inout this, builtinId: u32): u32 {
    const handle = this.allocate(TAG_HOST_FUNCTION, 0);
    this.headers[usize(handle)].payload = builtinId;
    return handle;
  }

  function isHostFunction(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_HOST_FUNCTION;
  }

  function hostFunctionId(handle: u32): u32 {
    return this.headers[usize(handle)].payload;
  }

  // A string cell owning `bytes`.
  function allocateString(inout this, bytes: Array<u8>): u32 {
    let stringIndex: u32 = 0;
    if (this.freeStringCount > 0) {
      this.freeStringCount = this.freeStringCount - 1;
      stringIndex = this.freeStrings[this.freeStringCount];
      this.strings[usize(stringIndex)] = move bytes;
    } else {
      stringIndex = u32(this.strings.length);
      this.strings.push(move bytes);
    }
    const handle = this.allocate(TAG_STRING, 0);
    this.headers[usize(handle)].payload = stringIndex;
    return handle;
  }

  // A string cell holding a copy of a Z String's bytes.
  function allocateText(inout this, in text: String): u32 {
    return this.allocateString(bytesOf(in text));
  }

  function isString(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_STRING;
  }

  // A function cell referring to compiled code by index.
  function allocateFunction(inout this, functionIndex: u32): u32 {
    const handle = this.allocate(TAG_FUNCTION, 0);
    this.headers[usize(handle)].payload = functionIndex;
    return handle;
  }

  function isFunction(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_FUNCTION;
  }

  function functionIndex(handle: u32): u32 {
    return this.headers[usize(handle)].payload;
  }

  function stringLength(handle: u32): usize {
    return this.strings[usize(this.headers[usize(handle)].payload)].length;
  }

  function stringByte(handle: u32, index: usize): u8 {
    return this.strings[usize(this.headers[usize(handle)].payload)][index];
  }

  // An owned copy of a string cell's bytes.
  function stringBytes(handle: u32): Array<u8> {
    const at = usize(this.headers[usize(handle)].payload);
    let copied = Array<u8>();
    let index: usize = 0;
    const length = this.strings[at].length;
    while (index < length) {
      copied.push(this.strings[at][index]);
      index = index + 1;
    }
    return copied;
  }

  function stringsEqual(a: u32, b: u32): boolean {
    if (a == b) return true;
    const length = this.stringLength(a);
    if (length != this.stringLength(b)) return false;
    let index: usize = 0;
    while (index < length) {
      if (this.stringByte(a, index) != this.stringByte(b, index)) return false;
      index = index + 1;
    }
    return true;
  }

  // Byte-wise ordering, the reference's memcmp-then-length rule:
  // negative, zero, or positive.
  function compareStrings(a: u32, b: u32): i32 {
    const aLength = this.stringLength(a);
    const bLength = this.stringLength(b);
    const shorter = aLength < bLength ? aLength : bLength;
    let index: usize = 0;
    while (index < shorter) {
      const ab = this.stringByte(a, index);
      const bb = this.stringByte(b, index);
      if (ab < bb) return -1;
      if (ab > bb) return 1;
      index = index + 1;
    }
    if (aLength < bLength) return -1;
    if (aLength > bLength) return 1;
    return 0;
  }

  function allocateValue(inout this, tag: u8, slotCount: u32): Value {
    return cellValue(this.allocate(tag, slotCount));
  }

  function tagOf(handle: u32): u8 {
    return this.headers[usize(handle)].tag;
  }

  function slotCountOf(handle: u32): u32 {
    return this.headers[usize(handle)].slotCount;
  }

  function slot(handle: u32, index: u32): Value {
    const header = this.headers[usize(handle)];
    return this.slots[usize(header.slotStart + index)];
  }

  function setSlot(inout this, handle: u32, index: u32, value: Value): void {
    const start = this.headers[usize(handle)].slotStart;
    this.slots[usize(start + index)] = value;
  }

  function marked(handle: u32): boolean {
    return this.headers[usize(handle)].marked;
  }

  function setMarked(inout this, handle: u32, value: boolean): void {
    this.headers[usize(handle)].marked = value;
  }

  // Allocated cells, excluding the reserved handle 0.
  function liveCells(): u32 {
    return u32(this.headers.length - 1 - this.freeHandleCount);
  }

  function slotsInUse(): u32 {
    return u32(this.slots.length);
  }
}

export function createHeap(): Heap {
  let headers = Array<CellHeader>();
  // Handle 0 is reserved; push a sentinel so live handles start at 1.
  headers.push(CellHeader({ tag: TAG_RESERVED, marked: false, slotStart: 0, slotCount: 0, payload: 0, link: 0 }));
  let classes = Array<HiddenClass>();
  // Class 0 is the empty root every object starts from.
  classes.push(HiddenClass({
    parent: 0, transitionName: 0, transitionSlot: 0, propCount: 0,
    transitionNames: Array<u32>(), transitionChildren: Array<u32>(),
  }));
  return Heap({
    headers: move headers, slots: Array<Value>(), strings: Array<Array<u8>>(), classes: move classes,
    freeHandles: Array<u32>(), freeHandleCount: 0, freeStrings: Array<u32>(), freeStringCount: 0,
    markStack: Array<u32>(), markCount: 0,
    allocatedSinceCollect: 0, collectThreshold: COLLECT_FLOOR, collections: 0,
  });
}

// The fewest allocations between collections.
const COLLECT_FLOOR: u32 = 4096;

// The bytes of a Z String as an owned byte array.
export function bytesOf(in text: String): Array<u8> {
  let bytes = Array<u8>();
  let index: usize = 0;
  const length = text.byteLength;
  while (index < length) {
    bytes.push(text.byteAt(index));
    index = index + 1;
  }
  return bytes;
}

// --- Tests ----------------------------------------------------------------

function int32Slot(value: i32): Value {
  return int32Value(value);
}

test "a fresh heap has no live cells and reserves handle 0" {
  const heap = createHeap();
  expect(heap.liveCells()).toEqual(0);
  expect(heap.tagOf(0)).toEqual(TAG_RESERVED);
}

test "allocation yields handles starting at one" {
  let heap = createHeap();
  const first = heap.allocate(TAG_OBJECT, 4);
  const second = heap.allocate(TAG_ARRAY, 2);
  expect(first).toEqual(1);
  expect(second).toEqual(2);
  expect(heap.liveCells()).toEqual(2);
}

test "tags and slot counts survive allocation" {
  let heap = createHeap();
  const object = heap.allocate(TAG_OBJECT, 4);
  const text = heap.allocate(TAG_STRING, 1);
  expect(heap.tagOf(object)).toEqual(TAG_OBJECT);
  expect(heap.tagOf(text)).toEqual(TAG_STRING);
  expect(heap.slotCountOf(object)).toEqual(4);
  expect(heap.slotCountOf(text)).toEqual(1);
}

test "slots initialize to undefined" {
  let heap = createHeap();
  const object = heap.allocate(TAG_OBJECT, 3);
  expect(heap.slot(object, 0).bits).toEqual(undefinedValue().bits);
  expect(heap.slot(object, 2).bits).toEqual(undefinedValue().bits);
}

test "slots round-trip and neighbouring cells stay independent" {
  let heap = createHeap();
  const first = heap.allocate(TAG_OBJECT, 2);
  const second = heap.allocate(TAG_OBJECT, 2);

  heap.setSlot(first, 0, int32Slot(11));
  heap.setSlot(first, 1, int32Slot(22));
  heap.setSlot(second, 0, int32Slot(33));

  expect(heap.slot(first, 0).bits).toEqual(int32Slot(11).bits);
  expect(heap.slot(first, 1).bits).toEqual(int32Slot(22).bits);
  expect(heap.slot(second, 0).bits).toEqual(int32Slot(33).bits);
  // Writing `second` must not have disturbed `first`.
  expect(heap.slot(first, 1).bits).toEqual(int32Slot(22).bits);
  // And `second`'s untouched slot is still undefined.
  expect(heap.slot(second, 1).bits).toEqual(undefinedValue().bits);
}

test "a boxed cell round-trips through the heap" {
  let heap = createHeap();
  const boxed = heap.allocateValue(TAG_ARRAY, 1);
  expect(isCell(boxed)).toEqual(true);
  expect(heap.tagOf(asCell(boxed))).toEqual(TAG_ARRAY);

  // A cell stored in another cell's slot survives the round trip.
  const holder = heap.allocate(TAG_OBJECT, 1);
  heap.setSlot(holder, 0, boxed);
  const recovered = heap.slot(holder, 0);
  expect(isCell(recovered)).toEqual(true);
  expect(asCell(recovered)).toEqual(asCell(boxed));
}

test "mark bits are per-cell and default clear" {
  let heap = createHeap();
  const first = heap.allocate(TAG_OBJECT, 1);
  const second = heap.allocate(TAG_OBJECT, 1);
  expect(heap.marked(first)).toEqual(false);
  heap.setMarked(first, true);
  expect(heap.marked(first)).toEqual(true);
  expect(heap.marked(second)).toEqual(false);
}

test "string cells keep their bytes and compare bytewise" {
  let heap = createHeap();
  const hello = heap.allocateText("hello");
  const help = heap.allocateText("help");
  const helloAgain = heap.allocateText("hello");
  expect(heap.isString(hello)).toEqual(true);
  const five: usize = 5;
  expect(heap.stringLength(hello)).toEqual(five);
  expect(heap.stringByte(hello, 1)).toEqual(101);
  expect(heap.stringsEqual(hello, helloAgain)).toEqual(true);
  expect(heap.stringsEqual(hello, help)).toEqual(false);
  expect(heap.compareStrings(hello, help) < 0).toEqual(true);
  expect(heap.compareStrings(help, hello) > 0).toEqual(true);
  const prefix = heap.allocateText("hel");
  expect(heap.compareStrings(prefix, hello) < 0).toEqual(true);
  const copied = heap.stringBytes(hello);
  expect(copied.length).toEqual(five);
  expect(copied[4]).toEqual(111);
}

test "objects add properties through shared class transitions" {
  let heap = createHeap();
  const textA: String = "a";
  const textB: String = "b";
  const nameA = heap.allocateString(bytesOf(in textA));
  const nameB = heap.allocateString(bytesOf(in textB));
  const first = heap.allocateObject(0);
  const second = heap.allocateObject(0);
  heap.objectSet(first, nameA, int32Value(1));
  heap.objectSet(first, nameB, int32Value(2));
  heap.objectSet(second, nameA, int32Value(10));
  heap.objectSet(second, nameB, int32Value(20));
  expect(heap.objectClass(first)).toEqual(heap.objectClass(second));
  expect(heap.objectFindSlot(first, nameA)).toEqual(0);
  expect(heap.objectFindSlot(first, nameB)).toEqual(1);
  expect(asInt32(heap.slot(second, 1))).toEqual(20);
  heap.objectSet(first, nameA, int32Value(7));
  expect(asInt32(heap.slot(first, 0))).toEqual(7);
  expect(heap.objectFindSlot(first, 12345)).toEqual(-1);
}

test "an object outgrows its initial slots" {
  let heap = createHeap();
  const object = heap.allocateObject(0);
  let i: i32 = 0;
  while (i < 10) {
    const text: String = `p${i}`;
    const name = heap.allocateString(bytesOf(in text));
    heap.objectSet(object, name, int32Value(i));
    i = i + 1;
  }
  expect(heap.classPropCount(heap.objectClass(object))).toEqual(10);
  const textP9: String = "p9";
  const p9 = heap.allocateString(bytesOf(in textP9));
  // Names are compared by handle; a different cell with the same bytes
  // is a different atom. The runtime interns before it asks the heap.
  expect(heap.objectFindSlot(object, p9)).toEqual(-1);
  expect(asInt32(heap.slot(object, 9))).toEqual(9);
}

test "arrays grow, keep holes, and shrink" {
  let heap = createHeap();
  const array = heap.allocateArray(0);
  expect(heap.arrayLength(array)).toEqual(0);
  heap.arraySet(array, 0, int32Value(5));
  heap.arraySet(array, 6, int32Value(6));
  expect(heap.arrayLength(array)).toEqual(7);
  expect(heap.arrayHasIndex(array, 3)).toEqual(false);
  expect(asInt32(heap.arrayGet(array, 6))).toEqual(6);
  heap.setArrayLength(array, 1);
  expect(heap.arrayHasIndex(array, 6)).toEqual(false);
  expect(asInt32(heap.arrayGet(array, 0))).toEqual(5);
}

test "a sweep frees unmarked cells, compacts slots, and reuses handles" {
  let heap = createHeap();
  const kept = heap.allocateObject(0);
  const dropped = heap.allocateObject(0);
  const textKept: String = "kept";
  const textDropped: String = "dropped";
  const keptString = heap.allocateString(bytesOf(in textKept));
  const droppedString = heap.allocateString(bytesOf(in textDropped));
  const child = heap.allocateArray(2);
  heap.setSlot(kept, 0, cellValue(child));
  heap.setSlot(child, 0, cellValue(keptString));
  heap.objectSet(dropped, keptString, cellValue(droppedString));
  const slotsBefore = heap.slotsInUse();
  heap.markHandle(kept);
  heap.sweep();
  expect(heap.liveCells()).toEqual(3);
  expect(heap.tagOf(dropped)).toEqual(TAG_FREE);
  expect(heap.tagOf(droppedString)).toEqual(TAG_FREE);
  expect(heap.isArray(child)).toEqual(true);
  expect(heap.stringLength(keptString)).toEqual(4);
  expect(heap.slotsInUse() < slotsBefore).toEqual(true);
  expect(asCell(heap.slot(child, 0))).toEqual(keptString);
  // The freed handle and string index come back before the arrays grow.
  const headersBefore = heap.headers.length;
  const reused = heap.allocateString(bytesOf(in textDropped));
  expect(reused == dropped || reused == droppedString).toEqual(true);
  expect(heap.headers.length).toEqual(headersBefore);
  expect(heap.stringLength(reused)).toEqual(7);
}

test "marking follows links: prototypes, environments, closures" {
  let heap = createHeap();
  const proto = heap.allocateObject(0);
  const object = heap.allocateObject(proto);
  const outerEnv = heap.allocateEnv(0, 1);
  const innerEnv = heap.allocateEnv(outerEnv, 1);
  const fn = heap.allocateFunction(3);
  const closure = heap.allocateClosure(3, innerEnv, cellValue(object));
  const unreachable = heap.allocateObject(0);
  heap.setSlot(outerEnv, 0, cellValue(fn));
  heap.markHandle(closure);
  heap.sweep();
  expect(heap.tagOf(proto)).toEqual(TAG_OBJECT);
  expect(heap.tagOf(outerEnv)).toEqual(TAG_ENV);
  expect(heap.tagOf(fn)).toEqual(TAG_FUNCTION);
  expect(heap.tagOf(unreachable)).toEqual(TAG_FREE);
  expect(heap.liveCells()).toEqual(6);
}
