// G13b — contextual typing of a literal before a shift.  STATUS: proposed
//
// Confirmed at z-lang 00864194 (Stage 0): `const mask: u64 = 0xFFFE << 48`
// fails because the shift is checked as i32 before the destination context
// reaches the literal. G1 made the spelling legal; this is what stops it
// being usable for the NaN-box tag it exists to express.
//
// The engine sidesteps it with full-width constants (0xFFFE_0000_0000_0000).
import console from "std/console";

function main(): i32 {
  const mask: u64 = 0xFFFE << 48;
  if (mask != 0xFFFE_0000_0000_0000) return 1;
  console.log("g13b ok");
  return 0;
}
