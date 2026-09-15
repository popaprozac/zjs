// G11 — bit-preserving *integer* conversion.  STATUS: proposed (API pending)
//
// The integer half of what dee8ea80 landed for floats. Integers still have
// only the checked, value-preserving constructors, which trap rather than
// reinterpret: `u32(-42)` aborts.
//
// ZJS use case: boxing an int32 into a NaN-boxed value needs C's
// `(uint32_t)i`. The engine folds the sign by hand today
// (int32Value/asInt32 in z/engine/value.zs).
//
// Spelling below is Codex's recommendation from review at 00864194. It is a
// RECOMMENDATION, NOT AN APPROVED EXTENSION. In particular
// `u32.fromBits(negative)` was considered and is not approved. Checked
// constructors keep their existing trapping behaviour regardless.
import console from "std/console";

function main(): i32 {
  const negative: i32 = -42;
  const minimum: i32 = -2147483648;

  // Reinterpret, do not convert: the value changes, the bits do not.
  const bits: u32 = negative.toBits();
  if (bits != 0xFFFF_FFD6) return 1;
  if (minimum.toBits() != 0x8000_0000) return 2;

  // And back.
  const restored = i32.fromBits(bits);
  if (restored != -42) return 3;
  if (i32.fromBits(0x8000_0000) != minimum) return 4;

  console.log("g11 ok");
  return 0;
}
