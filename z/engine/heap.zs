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
// This is allocation-only: there is no collector yet. Phase 6 adds marking
// over `headers`, which is why the mark bit already exists here.

import { expect } from "std/test";
import { Value, undefinedValue, cellValue, asCell, isCell, int32Value } from "./value.zs";

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

// Reserved for the unallocatable handle 0.
export const TAG_RESERVED: u8 = 255;

struct CellHeader {
  tag: u8;
  marked: boolean;
  slotStart: u32;
  slotCount: u32;
  // Tag-specific extra: for a string cell, the index of its bytes in
  // `strings`. Zero-initialized and unused by other tags.
  payload: u32;
}

// String cells keep their bytes in a Z-owned Array<u8>, held in a side
// table indexed through the cell header's payload. The reference stores
// plain bytes with a byte length and byte-indexed access -- including
// embedded NULs, which is why the storage is bytes rather than a Z String.
export struct Heap {
  headers: Array<CellHeader>;
  slots: Array<Value>;
  strings: Array<Array<u8>>;

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
    this.headers.push(CellHeader({
      tag: tag,
      marked: false,
      slotStart: start,
      slotCount: slotCount,
      payload: 0,
    }));
    return u32(this.headers.length - 1);
  }

  // A string cell owning `bytes`.
  function allocateString(inout this, bytes: Array<u8>): u32 {
    const stringIndex = u32(this.strings.length);
    this.strings.push(move bytes);
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
    return u32(this.headers.length - 1);
  }

  function slotsInUse(): u32 {
    return u32(this.slots.length);
  }
}

export function createHeap(): Heap {
  let headers = Array<CellHeader>();
  // Handle 0 is reserved; push a sentinel so live handles start at 1.
  headers.push(CellHeader({ tag: TAG_RESERVED, marked: false, slotStart: 0, slotCount: 0, payload: 0 }));
  return Heap({ headers: move headers, slots: Array<Value>(), strings: Array<Array<u8>>() });
}

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
