// G13 — contextual typing of integer literals.  STATUS: open
//
// Each line below is an error today. All three shapes occur constantly in
// bit-manipulation code, and the third one is the bad case: it is not
// reported as a Z diagnostic at all -- it escapes into generated C as a
// clang -Wsign-compare error with no Z source location.
import console from "std/console";
import { expect } from "std/test";

function pick(flag: boolean): u64 {
  return flag ? 7 : 6;                 // expected u64, found i32
}

function inRange(sum: i64): boolean {
  return sum >= -2147483648 && sum <= 2147483647;   // operands must match
}

test "u32 actuals accept plain literals" {
  const handle: u32 = 1;
  expect(handle).toEqual(1);           // escapes into generated C today
}

function main(): i32 {
  if (pick(true) != 7) return 1;
  if (!inRange(0)) return 2;
  console.log("g13 ok");
  return 0;
}
