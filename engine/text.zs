// Text: the engine's string content is UTF-16 code units, as the
// specification defines it. This module is the pure arithmetic over
// units and the two byte boundaries: UTF-8 coming in (source text, host
// text, Z string literals) and UTF-8 going out (host output). The heap
// decides how units are stored; nothing here touches cells.
//
// Boundary policy, in both directions explicit and lossless where it can
// be: a byte that is not part of a well-formed UTF-8 sequence becomes the
// unit with that byte's value (so nothing is dropped and text that was
// never UTF-8 stays byte-for-byte); a lone surrogate going out is written
// as U+FFFD, since UTF-8 cannot carry it (unitsToWtf8 keeps it, for a
// consumer that decodes generalized UTF-8).

export function textBytes(in text: String): Array<u8> {
  let bytes = Array<u8>.withCapacity(text.byteLength);
  let index: usize = 0;
  const length = text.byteLength;
  while (index < length) {
    bytes.push(text.byteAt(index));
    index = index + 1;
  }
  return bytes;
}

export function isAsciiBytes(in bytes: Array<u8>): boolean {
  let i: usize = 0;
  while (i < bytes.length) {
    if (bytes[i] >= 128) return false;
    i = i + 1;
  }
  return true;
}

// The length of the well-formed UTF-8 sequence starting at `at`, or 0.
export function utf8Length(in bytes: Array<u8>, at: usize): usize {
  return sequenceLength(in bytes, at, false);
}

// The same over generalized UTF-8, where a surrogate code point may be
// encoded (the form a lone surrogate takes when a string is handed back
// to the parser as source).
export function wtf8Length(in bytes: Array<u8>, at: usize): usize {
  return sequenceLength(in bytes, at, true);
}

function sequenceLength(in bytes: Array<u8>, at: usize, surrogates: boolean): usize {
  const lead = bytes[at];
  if (lead < 0x80) return 1;
  let need: usize = 0;
  let min: u32 = 0;
  if (lead >= 0xC2 && lead <= 0xDF) {
    need = 1;
    min = 0x80;
  } else if (lead >= 0xE0 && lead <= 0xEF) {
    need = 2;
    min = 0x800;
  } else if (lead >= 0xF0 && lead <= 0xF4) {
    need = 3;
    min = 0x10000;
  } else {
    return 0;
  }
  if (at + need >= bytes.length) return 0;
  let value: u32 = u32(lead) & u32(0x3F >> need);
  let k: usize = 1;
  while (k <= need) {
    const next = bytes[at + k];
    if ((next & 0xC0) != 0x80) return 0;
    value = (value << 6) | u32(next & 0x3F);
    k = k + 1;
  }
  if (value < min || value > 0x10FFFF) return 0;
  if (!surrogates && value >= 0xD800 && value <= 0xDFFF) return 0;
  return need + 1;
}

// The code point of the well-formed sequence of `length` bytes at `at`.
function utf8Value(in bytes: Array<u8>, at: usize, length: usize): u32 {
  if (length == 1) return u32(bytes[at]);
  let value: u32 = u32(bytes[at]) & u32(0x3F >> (length - 1));
  let k: usize = 1;
  while (k < length) {
    value = (value << 6) | u32(bytes[at + k] & 0x3F);
    k = k + 1;
  }
  return value;
}

export function pushCodePoint(inout units: Array<u16>, codePoint: u32): void {
  if (codePoint < 0x10000) {
    units.push(u16(codePoint));
    return;
  }
  if (codePoint > 0x10FFFF) {
    units.push(0xFFFD);
    return;
  }
  const offset = codePoint - 0x10000;
  units.push(u16(0xD800 + (offset >> 10)));
  units.push(u16(0xDC00 + (offset & 0x3FF)));
}

export function utf8ToUnits(in bytes: Array<u8>): Array<u16> {
  let units = Array<u16>.withCapacity(bytes.length);
  let at: usize = 0;
  while (at < bytes.length) {
    const length = utf8Length(in bytes, at);
    if (length <= 1) {
      units.push(u16(bytes[at]));
      at = at + 1;
      continue;
    }
    pushCodePoint(inout units, utf8Value(in bytes, at, length));
    at = at + length;
  }
  return units;
}

export function unitsOf(in text: String): Array<u16> {
  const bytes = textBytes(in text);
  return utf8ToUnits(in bytes);
}

function pushUtf8(inout bytes: Array<u8>, codePoint: u32): void {
  if (codePoint < 0x80) {
    bytes.push(u8(codePoint));
  } else if (codePoint < 0x800) {
    bytes.push(u8(0xC0 | (codePoint >> 6)));
    bytes.push(u8(0x80 | (codePoint & 0x3F)));
  } else if (codePoint < 0x10000) {
    bytes.push(u8(0xE0 | (codePoint >> 12)));
    bytes.push(u8(0x80 | ((codePoint >> 6) & 0x3F)));
    bytes.push(u8(0x80 | (codePoint & 0x3F)));
  } else {
    bytes.push(u8(0xF0 | (codePoint >> 18)));
    bytes.push(u8(0x80 | ((codePoint >> 12) & 0x3F)));
    bytes.push(u8(0x80 | ((codePoint >> 6) & 0x3F)));
    bytes.push(u8(0x80 | (codePoint & 0x3F)));
  }
}

export function isHighSurrogate(unit: u16): boolean {
  return unit >= 0xD800 && unit <= 0xDBFF;
}

export function isLowSurrogate(unit: u16): boolean {
  return unit >= 0xDC00 && unit <= 0xDFFF;
}

// The code point at `index`: a surrogate pair combined, anything else
// (a lone surrogate included) as itself.
export function codePointAt(in units: Array<u16>, index: usize): u32 {
  const first = units[index];
  if (isHighSurrogate(first) && index + 1 < units.length && isLowSurrogate(units[index + 1])) {
    return 0x10000 + ((u32(first) - 0xD800) << 10) + (u32(units[index + 1]) - 0xDC00);
  }
  return u32(first);
}

// UTF-8, with `keepSurrogates` choosing between U+FFFD and the
// generalized three-byte form for a lone surrogate.
function encodeUnits(in units: Array<u16>, keepSurrogates: boolean): Array<u8> {
  let bytes = Array<u8>.withCapacity(units.length);
  let index: usize = 0;
  while (index < units.length) {
    const unit = units[index];
    if (unit < 0x80) {
      bytes.push(u8(unit));
      index = index + 1;
      continue;
    }
    const codePoint = codePointAt(in units, index);
    if (codePoint >= 0x10000) {
      index = index + 2;
    } else {
      index = index + 1;
    }
    if (codePoint >= 0xD800 && codePoint <= 0xDFFF && !keepSurrogates) {
      pushUtf8(inout bytes, 0xFFFD);
    } else {
      pushUtf8(inout bytes, codePoint);
    }
  }
  return bytes;
}

export function unitsToUtf8(in units: Array<u16>): Array<u8> {
  return encodeUnits(in units, false);
}

export function unitsToWtf8(in units: Array<u16>): Array<u8> {
  return encodeUnits(in units, true);
}

export function isNarrowUnits(in units: Array<u16>): boolean {
  let i: usize = 0;
  while (i < units.length) {
    if (units[i] > 0xFF) return false;
    i = i + 1;
  }
  return true;
}

// Latin-1 bytes as units, and back (the caller keeps every unit under
// 0x100).
export function latin1Units(in bytes: Array<u8>): Array<u16> {
  let units = Array<u16>.withCapacity(bytes.length);
  let i: usize = 0;
  while (i < bytes.length) {
    units.push(u16(bytes[i]));
    i = i + 1;
  }
  return units;
}

export function unitsToLatin1(in units: Array<u16>): Array<u8> {
  let bytes = Array<u8>.withCapacity(units.length);
  let i: usize = 0;
  while (i < units.length) {
    bytes.push(u8(units[i]));
    i = i + 1;
  }
  return bytes;
}

export function sliceUnits(in units: Array<u16>, start: usize, end: usize): Array<u16> {
  let count: usize = 0;
  if (end > start) count = end - start;
  let copy = Array<u16>.withCapacity(count);
  if (count > 0) copy.append(units.slice(start, end));
  return copy;
}

export function copyUnits(in units: Array<u16>): Array<u16> {
  const end = units.length;
  return sliceUnits(in units, 0, end);
}

export function appendUnits(inout target: Array<u16>, source: Array<u16>): void {
  target.append(source);
}

// source[start, end) onto target in one copy.
export function appendUnitRange(inout target: Array<u16>, in source: Array<u16>, start: usize, end: usize): void {
  if (end <= start) return;
  target.append(source.slice(start, end));
}

export function appendText(inout target: Array<u16>, in text: String): void {
  appendUnits(inout target, unitsOf(in text));
}

export function sameUnits(in a: Array<u16>, in b: Array<u16>): boolean {
  if (a.length != b.length) return false;
  let i: usize = 0;
  while (i < a.length) {
    if (a[i] != b[i]) return false;
    i = i + 1;
  }
  return true;
}

export function unitsEqualText(in units: Array<u16>, in text: String): boolean {
  const expected = unitsOf(in text);
  return sameUnits(in units, in expected);
}

// The first index at or after `start` where `needle` occurs, or -1.
export function findUnits(in haystack: Array<u16>, in needle: Array<u16>, start: usize): i32 {
  if (needle.length > haystack.length) return -1;
  const last = haystack.length - needle.length;
  let at = start;
  while (at <= last) {
    let k: usize = 0;
    while (k < needle.length && haystack[at + k] == needle[k]) { k = k + 1; }
    if (k == needle.length) return i32(at);
    at = at + 1;
  }
  return -1;
}

// The last index at or before `start` where `needle` occurs, or -1.
export function findLastUnits(in haystack: Array<u16>, in needle: Array<u16>, start: usize): i32 {
  if (needle.length > haystack.length) return -1;
  let at = start;
  const last = haystack.length - needle.length;
  if (at > last) at = last;
  while (true) {
    let k: usize = 0;
    while (k < needle.length && haystack[at + k] == needle[k]) { k = k + 1; }
    if (k == needle.length) return i32(at);
    if (at == 0) return -1;
    at = at - 1;
  }
  return -1;
}

export function isAsciiDigit(unit: u16): boolean {
  return unit >= 48 && unit <= 57;
}

// WhiteSpace and LineTerminator, as the specification lists them.
export function isJsSpace(unit: u16): boolean {
  if (unit == 9 || unit == 10 || unit == 11 || unit == 12 || unit == 13 || unit == 32) return true;
  if (unit == 0xA0 || unit == 0x1680 || unit == 0x2028 || unit == 0x2029 || unit == 0x202F || unit == 0x205F || unit == 0x3000 || unit == 0xFEFF) return true;
  return unit >= 0x2000 && unit <= 0x200A;
}

// Simple case mapping for ASCII and Latin-1 letters; other units are
// returned unchanged (the full Unicode tables are not here).
export function upperUnit(unit: u16): u16 {
  if (unit >= 97 && unit <= 122) return unit - 32;
  if (unit >= 0xE0 && unit <= 0xFE && unit != 0xF7) return unit - 32;
  if (unit == 0xFF) return 0x178;
  if (unit == 0xB5) return 0x39C;
  return unit;
}

export function lowerUnit(unit: u16): u16 {
  if (unit >= 65 && unit <= 90) return unit + 32;
  if (unit >= 0xC0 && unit <= 0xDE && unit != 0xD7) return unit + 32;
  if (unit == 0x178) return 0xFF;
  return unit;
}
