// A String's bytes cannot reach native code without a byte-by-byte copy.
//
// Found writing the ZJS parser: decimal literals need C's strtod (Z has no
// string-to-float), but `type "String" cannot cross a raw native boundary
// in the first tier`, and there is no way to view a String as a `cstring`
// either. The engine copies each byte into a calloc'd buffer through a
// usize handle, which works and is exact, but every string-heavy native
// call pays an allocation and a loop.
//
// The spelling below is a proposal only: a non-escaping borrowed view of a
// String's NUL-terminated bytes, usable as a raw c operand. Any equivalent
// that lets native code read a String's bytes without a copy is fine.
import console from "std/console";
import stdlib from "stdlib.h";

function parseDouble(text: cstring): f64 = raw c {
  return strtod(text, NULL);
}

function main(): i32 {
  const text: String = "2.5e1";
  if (parseDouble(text.asCString()) != 25.0) return 1;
  console.log("ok");
  return 0;
}
