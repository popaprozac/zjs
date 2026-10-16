// A truncating conversion from f64 to an integer.
//
// Found writing the ZJS builtins: JavaScript narrows by truncation
// everywhere (ToInt32, ToLength, ToIntegerOrInfinity), while Z's checked
// `i32(value)` / `u32(value)` trap on a fractional value and on NaN. Every
// such site in the engine calls a `raw c` `__builtin_trunc` first and
// compares, which keeps the intent in C rather than in Z.
//
// The spelling below uses `math.trunc` from `std/math`, which rounds toward
// zero while preserving the floating type, composed with the checked
// conversion. Any equivalent is fine; a conversion that names the
// offending value when it traps is a separate ask.
import console from "std/console";
import math from "std/math";

function main(): i32 {
  const pixels = u32(math.trunc(2.75));
  if (pixels != 2) return 1;
  const negative = i32(math.trunc(-0.5));
  if (negative != 0) return 2;
  const large = i32(math.trunc(-2147483647.9));
  if (large != -2147483647) return 3;
  const kept = math.trunc(3.0);
  if (kept != 3.0) return 4;
  console.log("ok");
  return 0;
}
