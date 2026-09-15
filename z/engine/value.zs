// NaN-boxed value representation, JSC layout.
//
// Mirrors the reference engine's encoding (src/value.zc) with one deliberate
// divergence: a cell payload is a *handle* into the Z-owned heap, not a
// machine address. See `cellValue` below for why that changes the encoding.
//
// G1 (radix literals + digit separators) landed in z-lang 135b64c9, so the
// constants below are spelled in the base that makes them reviewable.
// Still outstanding: Z has no bitcast (G2, in progress), so f64<->u64 punning
// goes through raw c; and Z's numeric construction is checked and traps rather
// than reinterpreting a sign bit (G11), so int32 boxing folds the sign by hand.

import string from "string.h";
import { expect } from "std/test";

export struct Value {
  bits: u64;
}

// --- Encoding constants ---------------------------------------------------
//
//   int32      NUMBER_TAG | (u32)i
//   double     bits(d) + DOUBLE_ENCODE_OFFSET
//   cell       handle << 2
//   null       2   (OTHER_TAG)
//   false      6   (OTHER_TAG | BOOL_TAG)
//   true       7   (OTHER_TAG | BOOL_TAG | 1)
//   undefined  10  (OTHER_TAG | UNDEFINED_TAG)
//   deleted    65538

export const NUMBER_TAG: u64 = 0xFFFE_0000_0000_0000;
export const DOUBLE_ENCODE_OFFSET: u64 = 0x0002_0000_0000_0000;  // 1 << 49
export const NOT_CELL_MASK: u64 = 0xFFFE_0000_0000_0002;         // NUMBER_TAG | OTHER_TAG
export const INT32_PAYLOAD_MASK: u64 = 0x0000_0000_FFFF_FFFF;

export const VALUE_NULL: u64 = 0x2;
export const VALUE_FALSE: u64 = 0x6;
export const VALUE_TRUE: u64 = 0x7;
export const VALUE_UNDEFINED: u64 = 0xA;
export const VALUE_DELETED: u64 = 0x1_0002;

export function numberTag(): u64 { return NUMBER_TAG; }
export function doubleEncodeOffset(): u64 { return DOUBLE_ENCODE_OFFSET; }
export function notCellMask(): u64 { return NOT_CELL_MASK; }

// --- Bit reinterpretation (G2) -------------------------------------------

export function doubleToBits(value: f64): u64 = raw c {
  uint64_t bits;
  memcpy(&bits, &value, sizeof(bits));
  return bits;
}

export function bitsToDouble(bits: u64): f64 = raw c {
  double value;
  memcpy(&value, &bits, sizeof(value));
  return value;
}

// --- Numbers --------------------------------------------------------------

// G11: `u32(value)` traps on a negative input, so the sign bit is folded
// explicitly. This is what C spells `(uint32_t)i`.
export function int32Value(value: i32): Value {
  const widened: i64 = i64(value) & 0xFFFF_FFFF;
  return Value({ bits: numberTag() | u64(widened) });
}

export function asInt32(value: Value): i32 {
  const payload: u64 = value.bits & INT32_PAYLOAD_MASK;
  if (payload >= 0x8000_0000) return i32(i64(payload) - 0x1_0000_0000);
  return i32(payload);
}

export function doubleValue(value: f64): Value {
  return Value({ bits: doubleToBits(value).wrappingAdd(doubleEncodeOffset()) });
}

export function asDouble(value: Value): f64 {
  return bitsToDouble(value.bits.wrappingSubtract(doubleEncodeOffset()));
}

export function isNumber(value: Value): boolean {
  return (value.bits & numberTag()) != 0;
}

export function isInt32(value: Value): boolean {
  return (value.bits & numberTag()) == numberTag();
}

export function isDouble(value: Value): boolean {
  return isNumber(value) && !isInt32(value);
}

// --- Singletons -----------------------------------------------------------

export function nullValue(): Value { return Value({ bits: VALUE_NULL }); }
export function undefinedValue(): Value { return Value({ bits: VALUE_UNDEFINED }); }
export function deletedValue(): Value { return Value({ bits: VALUE_DELETED }); }

export function booleanValue(value: boolean): Value {
  const yes: u64 = VALUE_TRUE;
  const no: u64 = VALUE_FALSE;
  return Value({ bits: value ? yes : no });
}

export function isNull(value: Value): boolean { return value.bits == VALUE_NULL; }
export function isUndefined(value: Value): boolean { return value.bits == VALUE_UNDEFINED; }
export function isDeleted(value: Value): boolean { return value.bits == VALUE_DELETED; }
export function isBoolean(value: Value): boolean {
  return value.bits == VALUE_TRUE || value.bits == VALUE_FALSE;
}
export function isTrue(value: Value): boolean { return value.bits == VALUE_TRUE; }

// --- Cells ----------------------------------------------------------------
//
// The reference engine stores a machine address here and relies on real
// pointers never colliding with the small sentinel encodings (2, 6, 7, 10).
// Handles are small integers, so they *would* collide -- handle 2 would read
// as `null`. Shifting left by two keeps bit 1 clear, which is exactly the bit
// every sentinel sets, so `isCell` stays a single mask test and no handle can
// ever alias a sentinel. It costs 2 of 62 available handle bits.
//
// Handle 0 is reserved and never allocated, so a live cell is always >= 1.

export function cellValue(handle: u32): Value {
  return Value({ bits: u64(handle) << 2 });
}

export function asCell(value: Value): u32 {
  return u32(value.bits >> 2);
}

export function isCell(value: Value): boolean {
  return (value.bits & notCellMask()) == 0;
}

// --- Round-trip tests -----------------------------------------------------

test "int32 round-trips across the sign boundary" {
  expect(asInt32(int32Value(0))).toEqual(0);
  expect(asInt32(int32Value(42))).toEqual(42);
  expect(asInt32(int32Value(-42))).toEqual(-42);
  expect(asInt32(int32Value(2147483647))).toEqual(2147483647);
  expect(asInt32(int32Value(-2147483648))).toEqual(-2147483648);
}

test "int32 values classify as int32 numbers and not cells" {
  const value = int32Value(-7);
  expect(isInt32(value)).toEqual(true);
  expect(isNumber(value)).toEqual(true);
  expect(isDouble(value)).toEqual(false);
  expect(isCell(value)).toEqual(false);
}

test "double round-trips and classifies as a non-int32 number" {
  const value = doubleValue(3.5);
  expect(asDouble(value)).toEqual(3.5);
  expect(isDouble(value)).toEqual(true);
  expect(isInt32(value)).toEqual(false);
  expect(isCell(value)).toEqual(false);
  expect(asDouble(doubleValue(-0.125))).toEqual(-0.125);
}

test "singletons are distinct and none is a cell" {
  expect(isNull(nullValue())).toEqual(true);
  expect(isUndefined(undefinedValue())).toEqual(true);
  expect(isDeleted(deletedValue())).toEqual(true);
  expect(isTrue(booleanValue(true))).toEqual(true);
  expect(isTrue(booleanValue(false))).toEqual(false);
  expect(isBoolean(booleanValue(false))).toEqual(true);

  expect(isCell(nullValue())).toEqual(false);
  expect(isCell(undefinedValue())).toEqual(false);
  expect(isCell(deletedValue())).toEqual(false);
  expect(isCell(booleanValue(true))).toEqual(false);
  expect(isCell(booleanValue(false))).toEqual(false);
}

test "cell handles round-trip and never alias a sentinel" {
  // G13, and a sharper symptom of it: `toEqual` does not contextually type
  // its literal against a u32 actual. The mismatch is not reported as a Z
  // diagnostic -- it escapes into generated C and surfaces as a clang
  // -Wsign-compare error with no Z source location.
  const one: u32 = 1;
  const two: u32 = 2;
  const many: u32 = 1000000;
  expect(asCell(cellValue(1))).toEqual(one);
  expect(asCell(cellValue(2))).toEqual(two);
  expect(asCell(cellValue(1000000))).toEqual(many);
  expect(isCell(cellValue(1))).toEqual(true);
  expect(isCell(cellValue(1000000))).toEqual(true);

  // The collision this encoding exists to prevent: handle 2 must not read
  // as null, handle 3 must not read as false, and so on.
  expect(cellValue(2).bits == VALUE_NULL).toEqual(false);
  expect(cellValue(3).bits == VALUE_FALSE).toEqual(false);
  expect(cellValue(1).bits == VALUE_FALSE).toEqual(false);
  expect(isNumber(cellValue(1000000))).toEqual(false);
}
