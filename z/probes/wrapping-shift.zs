// A left shift that moves bits out of the word traps, and there is no
// wrapping form.
//
// Found writing the ZJS interpreter's `<<` and Math.random: JavaScript's
// shift discards the bits that leave a 32-bit word, and a xorshift
// generator discards them from a 64-bit one. Z checks the shift and traps
// -- silently, see the trap-reporting finding -- so both went through
// `raw c`. The arithmetic operators offer `wrappingAdd`,
// `wrappingSubtract`, and `wrappingMultiply`; the shifts offer nothing.
//
// The spelling below is a proposal only: `wrappingShiftLeft(count)` beside
// the other wrapping operations. Any equivalent is fine.
import console from "std/console";

function main(): i32 {
  const word: u32 = 3;
  const shifted = word.wrappingShiftLeft(31);
  if (shifted != 0x80000000) return 1;
  console.log("ok");
  return 0;
}
