// A String cannot be built from bytes the program already holds.
//
// Found writing the ZJS runtime: JavaScript strings live as Array<u8> (byte
// length, byte indexing, embedded NULs), and an error message is assembled
// from such pieces. There is no way to turn those bytes back into a String
// for a template literal or a diagnostic: `String.from` takes a borrowed
// cstring from native code, and nothing accepts an Array<u8>. The engine
// assembles its messages as byte arrays instead, which works but keeps
// every String-typed API (formatting, console, interpolation) out of reach
// for engine text.
//
// The spelling below is a proposal only: an owned String from a byte array,
// with the caller responsible for valid UTF-8 (or a checked variant that
// reports otherwise). Any equivalent is fine.
import console from "std/console";

function main(): i32 {
  let bytes = Array<u8>();
  bytes.push(111);
  bytes.push(107);
  const text = String.fromBytes(move bytes);
  if (text.byteLength != 2) return 1;
  console.log(text);
  return 0;
}
