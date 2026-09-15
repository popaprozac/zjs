// G20 — method call on a module-level String constant mis-lowers.  STATUS: proposed (compiler bug)
//
// Found at z-lang 00864194 (Stage 0) while writing the ZJS lexer.
// `z check` accepts this file. The generated C then contains `byteAt(0)`
// with the receiver dropped, and clang fails with "call to undeclared
// function 'byteAt'". The same call on a local String binding lowers
// correctly, which is the workaround the engine uses.
//
// Expected: prints "g20 ok". Actual: BACKEND-REJECTED.
import console from "std/console";

const TABLE: String = "abc";

function main(): i32 {
  if (TABLE.byteAt(0) != 97) return 1;
  if (TABLE.byteLength != 3) return 2;
  console.log("g20 ok");
  return 0;
}
