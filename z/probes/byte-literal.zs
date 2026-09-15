// No byte/character literal.
//
// Found writing the ZJS lexer. Z has no `char` type and
// no way to spell a byte as a character, so every byte a scanner tests is a
// named numeric constant: the lexer carries ~70 lines of `const B_SLASH:
// u8 = 47;` before any logic. Correctness reviews of a lexer are reviews
// of exactly those comparisons, and `47` is not reviewable where `'/'` is.
//
// The spelling below is a proposal only (`b'/'`, an ASCII byte literal of
// type u8, as in Rust). Any equivalent is fine; the ask is a reviewable
// spelling for a u8 that names an ASCII character.
import console from "std/console";

function isSlash(c: u8): boolean {
  return c == b'/';
}

function main(): i32 {
  const text: String = "a/b";
  if (!isSlash(text.byteAt(1))) return 1;
  if (isSlash(text.byteAt(0))) return 2;
  console.log("ok");
  return 0;
}
