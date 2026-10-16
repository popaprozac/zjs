// A slice's length is a usize wherever a usize is wanted: as a direct
// argument, in arithmetic, and through an inferred binding. The engine
// copies a slice into an array sized for it.
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
function copyWithRoom(source: Slice<u8>): Array<u8> {
  let bytes = Array<u8>.withCapacity(source.length * 2 + 1);
  let index: usize = 0;
  while (index < source.length) {
    bytes.push(source[index]);
    index = index + 1;
  }
  return bytes;
}
function inferredLength(source: Slice<u8>): usize {
  const count = source.length;
  let total: usize = 0;
  let index: usize = 0;
  while (index < count) {
    total = total + count;
    index = index + 1;
  }
  return total;
}

function main(): i32 {
  let bytes = Array<u8>.withCapacity(3);
  bytes.push(1);
  bytes.push(2);
  bytes.push(3);
  const copied = copyOf(bytes);
  if (copied.length != 3 || copied[2] != 3) return 1;
  const roomy = copyWithRoom(bytes);
  if (roomy.length != 3 || roomy.capacity < 7) return 2;
  if (inferredLength(bytes) != 9) return 3;
  console.log("ok");
  return 0;
}
