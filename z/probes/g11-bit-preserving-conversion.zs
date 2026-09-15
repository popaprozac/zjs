// G11 — bit-preserving integer conversion.  STATUS: open
//
// Pairs with G2 and is the reason to build them together: NaN boxing an
// int32 needs C's `(uint32_t)i` reinterpretation. Z's `u32(value)` is
// value-preserving and *traps* on a negative input, so today the engine
// folds the sign by hand (z/engine/value.zs). Checked conversion is right
// for ordinary code; this is the deliberate opt-out beside it.
//
// Written against the proposed `std/bits` spelling; rename freely.
import console from "std/console";
import { toU32, toI32 } from "std/bits";

function main(): i32 {
  // The case that traps today.
  if (toU32(-42) != 0xFFFF_FFD6) return 1;
  if (toU32(-2147483648) != 0x8000_0000) return 2;
  if (toU32(2147483647) != 0x7FFF_FFFF) return 3;

  // And the decode direction.
  if (toI32(0xFFFF_FFD6) != -42) return 4;
  if (toI32(0x8000_0000) != -2147483648) return 5;

  console.log("g11 ok");
  return 0;
}
