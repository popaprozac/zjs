// Spike: NaN-boxed value, JSC layout (same as the Zen-c reference engine).
//
// Z has no hex literals, so wide constants are built by
// shifting from small values -- the same workaround src/value.zc uses for
// Zen-c's 32-bit literal parsing.
//
// Z has no bitcast intrinsic, so f64<->u64 punning goes
// through `raw c` + memcpy.

import string from "string.h";

export struct Value {
  bits: u64;
}

// 0xfffe << 48
export function numberTag(): u64 {
  return u64(65534) << 48;
}

// 1 << 49
export function doubleEncodeOffset(): u64 {
  return u64(1) << 49;
}

// NUMBER_TAG | 2
export function notCellMask(): u64 {
  return numberTag() | 2;
}

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

// Z's numeric construction is *checked* -- `u32(-42)` traps
// rather than reinterpreting the bit pattern. NaN boxing needs the C
// `(uint32_t)i` reinterpretation, so the sign bit is folded by hand.
export function fromInt32(value: i32): Value {
  const widened: i64 = i64(value) & 4294967295;
  return Value({ bits: numberTag() | u64(widened) });
}

export function toInt32(value: Value): i32 {
  const payload: u64 = value.bits & 4294967295;
  if (payload >= 2147483648) return i32(i64(payload) - 4294967296);
  return i32(payload);
}

export function isInt32(value: Value): boolean {
  return (value.bits & numberTag()) == numberTag();
}

export function fromDouble(value: f64): Value {
  return Value({ bits: doubleToBits(value).wrappingAdd(doubleEncodeOffset()) });
}

export function toDouble(value: Value): f64 {
  return bitsToDouble(value.bits.wrappingSubtract(doubleEncodeOffset()));
}

export function isDouble(value: Value): boolean {
  if (isInt32(value)) return false;
  return (value.bits & notCellMask()) != 0;
}

export function fromBoolean(value: boolean): Value {
  const trueBits: u64 = 7;
  const falseBits: u64 = 6;
  return Value({ bits: value ? trueBits : falseBits });
}

export function isTruthy(value: Value): boolean {
  return value.bits == 7;
}

// Cell reference: payload in the low bits, high 16 zero.
export function fromCell(payload: u64): Value {
  return Value({ bits: payload });
}

export function toCell(value: Value): u64 {
  return value.bits;
}

export function isCell(value: Value): boolean {
  return (value.bits & notCellMask()) == 0;
}
