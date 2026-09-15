// G13a — contextual typing of a literal in ternary branches.  STATUS: proposed
//
// Confirmed at z-lang 00864194 (Stage 0): `return flag ? 7 : 6` from a u64
// function fails with "expected u64, found i32". The destination type is
// known; the literals in the branches should take it.
//
// The principle asked for is contextual typing of *literals* -- never
// implicit conversion of an already-typed variable.
import console from "std/console";

function pick(flag: boolean): u64 {
  return flag ? 7 : 6;
}

function main(): i32 {
  if (pick(true) != 7) return 1;
  if (pick(false) != 6) return 2;
  console.log("g13a ok");
  return 0;
}
