// G11 — bit-preserving *integer* conversion.  STATUS: open
//
// The integer half of what landed for floats in dee8ea80. That commit gave
// f64/f32 a `fromBits`/`toBits` pair that preserves representation instead of
// mathematical value; integers still have only the checked, value-preserving
// constructors, which trap rather than reinterpret.
//
// ZJS use case: boxing an int32 into a NaN-boxed value needs C's
// `(uint32_t)i` reinterpretation. `u32(-42)` traps today, so the engine folds
// the sign by hand (see asInt32/int32Value in z/engine/value.zs) -- arithmetic
// standing in for a representation change.
//
// Written against the idiom already shipped for floats, which seems like the
// obviously consistent spelling; any equivalent naming is fine.
import console from "std/console";

function main(): i32 {
  const negative: i32 = -42;
  const minimum: i32 = -2147483648;

  // Reinterpret, do not convert: the value changes, the bits do not.
  if (u32.fromBits(negative) != 0xFFFF_FFD6) return 1;
  if (u32.fromBits(minimum) != 0x8000_0000) return 2;
  if (negative.toBits() != 0xFFFF_FFD6) return 3;

  // And back.
  if (i32.fromBits(0xFFFF_FFD6) != -42) return 4;
  if (i32.fromBits(0x8000_0000) != minimum) return 5;

  // The checked constructor must keep trapping -- this is an opt-out beside
  // it, not a replacement for it.
  console.log("g11 ok");
  return 0;
}
