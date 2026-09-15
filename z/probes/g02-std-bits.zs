// G2 — std/bits.  STATUS: in progress (Codex)
//
// This is the ZJS acceptance case, written against the API proposed in
// docs/z-findings.md. If a different spelling is chosen, tell us the names
// and this file is a one-line change -- the *behaviour* below is what the
// engine needs, not the naming.
//
// Requirement: a bit-preserving f64<->u64 reinterpretation. This is the
// single most load-bearing operation in the engine; without it every NaN-box
// encode and decode goes through `raw c` + memcpy.
import console from "std/console";
import { bitcastToU64, bitcastToF64 } from "std/bits";

function main(): i32 {
  // A double must survive the round trip bit-exactly.
  const bits = bitcastToU64(3.5);
  if (bits != 0x400C_0000_0000_0000) return 1;
  if (bitcastToF64(bits) != 3.5) return 2;

  // Negative zero must not be confused with zero -- JS distinguishes them.
  const negativeZero = bitcastToU64(-0.0);
  if (negativeZero != 0x8000_0000_0000_0000) return 3;

  // The encode path the engine actually runs: bits + DOUBLE_ENCODE_OFFSET.
  const boxed = bitcastToU64(-0.125).wrappingAdd(0x0002_0000_0000_0000);
  const unboxed = bitcastToF64(boxed.wrappingSubtract(0x0002_0000_0000_0000));
  if (unboxed != -0.125) return 4;

  console.log("g02 ok");
  return 0;
}
