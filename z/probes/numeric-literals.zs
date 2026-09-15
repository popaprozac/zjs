// Radix literals and digit separators.
//
// ZJS use case: every NaN-box constant and mask, spelled reviewably.
import console from "std/console";

function main(): i32 {
  const numberTag: u64 = 0xFFFE_0000_0000_0000;
  const doubleOffset: u64 = 0x0002_0000_0000_0000;
  const payloadMask: u64 = 0x0000_0000_FFFF_FFFF;
  const flags: u8 = 0b1010_0101;
  const hexWithE: i32 = 0x1e5;   // `e` is a hex digit here, not an exponent
  if (numberTag == 0 || doubleOffset == 0 || payloadMask == 0) return 1;
  if (flags != 165 || hexWithE != 485) return 2;
  console.log("ok");
  return 0;
}
