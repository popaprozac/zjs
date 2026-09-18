// A slice's length is a usize wherever a usize is wanted.
import console from "std/console";
function copyOf(source: Slice<u8>): Array<u8> {
  let bytes = Array<u8>.withCapacity(source.length);
  let index: usize = 0;
  while (index < source.length) {
    bytes.push(source[index]);
    index = index + 1;
  }
  return bytes;
}
function main(): i32 {
  let bytes = Array<u8>.withCapacity(3);
  bytes.push(1);
  bytes.push(2);
  bytes.push(3);
  const copied = copyOf(bytes);
  if (copied.length != 3) return 1;
  console.log("ok");
  return 0;
}
