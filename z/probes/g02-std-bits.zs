// G2 — exact float bit representation.  STATUS: landed (z-lang dee8ea80)
//
// Shipped as methods on the primitives rather than a std/bits module:
//   f64.fromBits(u64) / f64.toBits()
//   f32.fromBits(u32) / f32.toBits()
//
// ZJS use case: the NaN-box encode and decode path. The property the engine
// depends on beyond a plain round trip is that NaN *payloads* survive --
// boxing stores data in NaN payload bits, so any canonicalization would
// destroy values.
import console from "std/console";

function main(): i32 {
  // Bit-exact round trip.
  if ((3.5).toBits() != 0x400C_0000_0000_0000) return 1;
  if (f64.fromBits(0x400C_0000_0000_0000) != 3.5) return 2;

  // Negative zero must stay distinct from zero -- JS distinguishes them.
  if ((-0.0).toBits() != 0x8000_0000_0000_0000) return 3;

  // The encode path the engine actually runs.
  const boxed = (-0.125).toBits().wrappingAdd(0x0002_0000_0000_0000);
  if (f64.fromBits(boxed.wrappingSubtract(0x0002_0000_0000_0000)) != -0.125) return 4;

  // NaN payloads must survive: this is what NaN boxing stores values in.
  const payload: u64 = 0x7FF8_0000_0000_0042;
  if (f64.fromBits(payload).toBits() != payload) return 5;

  console.log("g02 ok");
  return 0;
}
