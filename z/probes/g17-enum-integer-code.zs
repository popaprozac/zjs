// G17 — no outward integer conversion for enums.  STATUS: proposed
//
// Found at z-lang 00864194 writing the ZJS token dump. Neither a plain enum
// nor a `c enum` with a declared representation can be read as an integer:
// `u8(kind)` is rejected with "numeric construction requires a numeric value".
//
// ZJS use case: serializing token kinds and cell tags for the differential
// oracle, and any table indexed by enum. The engine generates a 110-arm
// `match` to reproduce the reference numbering instead.
//
// Spelling below is a proposal only. A `c enum` already fixes its
// representation; reading that representation outward is the ask. Inward
// (integer -> enum) construction is deliberately NOT requested here.
import console from "std/console";

c enum Kind: u8 { eof, invalid, identifier, number }

function main(): i32 {
  const kind = Kind.number;
  const code: u8 = kind.toBits();
  if (code != 3) return 1;
  console.log("g17 ok");
  return 0;
}
