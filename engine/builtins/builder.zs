// A text built a byte or a unit at a time: bytes while every unit fits
// in one, which is nearly always, and units once one does not; finished
// as a narrow or a wide string to match. The builtins that assemble
// strings use it, so none builds units only to narrow them when done.
import { replace } from "std/memory";
import { Value } from "../value.zs";
import { Runtime } from "../runtime.zs";
import { appendRange } from "../heap.zs";

export struct TextBuilder {
  bytes: Array<u8>;
  units: Array<u16>;
  wide: boolean;
}

export function textBuilder(capacity: usize): TextBuilder {
  return TextBuilder({ bytes: Array<u8>.withCapacity(capacity), units: Array<u16>(), wide: false });
}

export inline function putByte(inout text: TextBuilder, byte: u8): void {
  if (text.wide) {
    text.units.push(u16(byte));
    return;
  }
  text.bytes.push(byte);
}

export function putUnit(inout text: TextBuilder, unit: u16): void {
  if (!text.wide) {
    if (unit <= 0xFF) {
      text.bytes.push(u8(unit));
      return;
    }
    // The first unit past a byte: what is written so far becomes units.
    let units = Array<u16>.withCapacity(text.bytes.length * 2 + 16);
    let index: usize = 0;
    while (index < text.bytes.length) {
      units.push(u16(text.bytes[index]));
      index = index + 1;
    }
    text.units = move units;
    text.bytes = Array<u8>();
    text.wide = true;
  }
  text.units.push(unit);
}

export function putUnits(inout text: TextBuilder, in units: Array<u16>): void {
  let index: usize = 0;
  while (index < units.length) {
    putUnit(inout text, units[index]);
    index = index + 1;
  }
}

// A string's content as it is: a narrow string's bytes read from its
// storage, where they are.
export function putString(in runtime: Runtime, inout text: TextBuilder, handle: u32): void {
  const length = runtime.heap.stringLength(handle);
  putStringRange(in runtime, inout text, handle, 0, length);
}

// Units `start` to `end` of a string, as putString puts all of them.
export function putStringRange(in runtime: Runtime, inout text: TextBuilder, handle: u32, start: usize, end: usize): void {
  let index = start;
  if (runtime.heap.isWideString(handle)) {
    while (index < end) {
      putUnit(inout text, runtime.heap.stringUnit(handle, index));
      index = index + 1;
    }
    return;
  }
  if (text.wide) {
    while (index < end) {
      text.units.push(u16(runtime.heap.stringStorageByte(handle, index)));
      index = index + 1;
    }
    return;
  }
  // The storage passed as a slice and the bytes moved into a local.
  let bytes = replace(inout text.bytes, Array<u8>());
  if (runtime.heap.isArenaString(handle)) {
    const origin = runtime.heap.stringStorageStart(handle);
    bytes = appendRange(runtime.heap.smallBytes, origin + start, origin + end, move bytes);
  } else {
    bytes = appendRange(runtime.heap.strings[usize(runtime.heap.stringBuffer(handle))], start, end, move bytes);
  }
  const emptied = replace(inout text.bytes, move bytes);
}

// Bytes `first` to `last` of `source`, appended at once while the text is
// narrow.
export function putByteRun(inout text: TextBuilder, source: Slice<u8>, first: usize, last: usize): void {
  if (text.wide) {
    let index = first;
    while (index < last) {
      text.units.push(u16(source[index]));
      index = index + 1;
    }
    return;
  }
  text.bytes.append(source.slice(first, last));
}

export function textLength(in text: TextBuilder): usize {
  return text.wide ? text.units.length : text.bytes.length;
}

// Drop what was written after `mark`.
export function truncateTo(inout text: TextBuilder, mark: usize): void {
  if (text.wide) {
    while (text.units.length > mark) {
      const dropped = text.units.pop();
    }
    return;
  }
  while (text.bytes.length > mark) {
    const dropped = text.bytes.pop();
  }
}

// The finished text as a string; the builder is left empty.
export function finishText(inout runtime: Runtime, inout text: TextBuilder): Value {
  if (text.wide) {
    const units = replace(inout text.units, Array<u16>());
    return runtime.newStringUnits(move units);
  }
  const bytes = replace(inout text.bytes, Array<u8>());
  return runtime.newStringLatin1(move bytes);
}
