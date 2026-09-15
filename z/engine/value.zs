// NaN-boxed value representation, JSC layout.
//
// Mirrors the reference engine's encoding (src/value.zc) with one deliberate
// divergence: a cell payload is a *handle* into the Z-owned heap, not a
// machine address. See `cellValue` below for why that changes the encoding.
//
// G1 (radix literals, z-lang 135b64c9) and G2 (exact float bit
// representation, dee8ea80) have both landed, so constants are spelled in the
// base that reads best and the NaN-box encode path is ordinary Z -- no raw c.
//
// Still outstanding: G11, the integer half of the same idea. Z's numeric
// construction is checked and traps rather than reinterpreting a sign bit, so
// int32 boxing still folds the sign by hand below.

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
  return Value({ bits: value.toBits().wrappingAdd(DOUBLE_ENCODE_OFFSET) });
}

export function asDouble(value: Value): f64 {
  return f64.fromBits(value.bits.wrappingSubtract(DOUBLE_ENCODE_OFFSET));
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

test "NaN and the zero signs survive boxing" {
  // NaN boxing stores data in NaN payload bits, so the encoding must not
  // canonicalize them. This is the property f64.fromBits/.toBits promises
  // and the reason the engine can rely on it.
  const quietNan = f64.fromBits(0x7FF8_0000_0000_0042);
  expect(asDouble(doubleValue(quietNan)).toBits()).toEqual(quietNan.toBits());

  // -0.0 and 0.0 are distinct in JS and must stay distinct through the box.
  expect(asDouble(doubleValue(-0.0)).toBits()).toEqual((-0.0).toBits());
  expect(asDouble(doubleValue(0.0)).toBits()).toEqual((0.0).toBits());
  expect((-0.0).toBits() == (0.0).toBits()).toEqual(false);

  // Infinities round-trip. G13: the expected literal needs an explicit u64
  // binding, otherwise it types as i32 and the mismatch escapes into
  // generated C rather than being reported against this line.
  const positiveInfinity: u64 = 0x7FF0_0000_0000_0000;
  expect(asDouble(doubleValue(f64.fromBits(positiveInfinity))).toBits())
    .toEqual(positiveInfinity);
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
