// A String built from bytes the program already holds.
//
// Found writing the ZJS runtime: JavaScript strings live as Array<u8> (byte
// length, byte indexing, embedded NULs), and an error message is assembled
// from such pieces. Before String.fromBytes there was no way to turn those
// bytes back into a String for a template literal or a diagnostic:
// `String.from` takes a borrowed cstring from native code, and nothing
// accepted an Array<u8>. The engine assembled its messages as byte arrays
// instead, which worked but kept every String-typed API (formatting,
// console, interpolation) out of reach for engine text.
//
// The approved API: `String.fromBytes(bytes)` borrows the bytes through
// the Slice conversion, returns independent owned text, and throws
// Utf8Error on malformed input, with byteOffset at the end of the valid
// prefix.
import console from "std/console";
import { Utf8Error } from "std/text";

function decode(bytes: Slice<u8>): String throws Utf8Error {
  return try String.fromBytes(bytes);
}

function main(): i32 {
  let bytes = Array<u8>();
  bytes.push(111);
  bytes.push(107);
  const outcome = attempt decode(bytes);
  const text = match (outcome) {
    success(value) => value;
    failure(error) => "";
  };
  if (text.byteLength != 2) return 1;
  // The input stays usable after the borrow.
  if (bytes.length != 2) return 2;
  let bad = Array<u8>();
  bad.push(111);
  bad.push(255);
  const rejected = attempt decode(bad);
  const offset = match (rejected) {
    success(value) => -1;
    failure(error) => i32(error.byteOffset);
  };
  if (offset != 1) return 3;
  console.log(text);
  return 0;
}
