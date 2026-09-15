// An `in` borrow conflicts with a field read of the same value in one call.
//
// Found at z-lang 00864194 writing the ZJS lexer:
//
//     lookupKeyword(in text, 0, text.byteLength)
//     // error: overlapping in and value uses of "text" and "text.byteLength"
//
// Both uses are reads. `in` is an immutable borrow, and `byteLength` is a
// read-only projection; there is no mutation anywhere in the call. The
// workaround is to bind the length first, which is harmless but pushes a
// value away from its use for no safety gain.
//
// If the rule is intentional (uniform "one mention per call" simplicity),
// the diagnostic should say so and name the bind-first workaround.
import console from "std/console";

function count(in text: String, length: usize): usize {
  return length;
}

function main(): i32 {
  const text: String = "abc";
  if (count(in text, text.byteLength) != 3) return 1;
  console.log("ok");
  return 0;
}
