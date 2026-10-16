// A generic function over Array<T> may compare two elements: every
// instantiation the program makes is of a comparable T, and a check that
// depends on T is the instantiation's to make. The engine's string
// builtins search Latin-1 and UTF-16 storage with one generic body.
import console from "std/console";

function sameAt<T>(in left: Array<T>, in right: Array<T>, index: usize): boolean {
  return left[index] == right[index];
}
function differAt<T>(in left: Array<T>, in right: Array<T>, index: usize): boolean {
  return left[index] != right[index];
}
// The offset of `needle` in `haystack`, or -1: the engine's shape.
function find<T>(in haystack: Array<T>, in needle: Array<T>): i32 {
  if (needle.length > haystack.length) return -1;
  let start: usize = 0;
  while (start + needle.length <= haystack.length) {
    let matched = true;
    let k: usize = 0;
    while (matched && k < needle.length) {
      if (haystack[start + k] != needle[k]) matched = false;
      k = k + 1;
    }
    if (matched) return i32(start);
    start = start + 1;
  }
  return -1;
}

function main(): i32 {
  let bytes = Array<u8>.withCapacity(3);
  bytes.push(1);
  bytes.push(2);
  bytes.push(3);
  let otherBytes = Array<u8>.withCapacity(3);
  otherBytes.push(1);
  otherBytes.push(9);
  otherBytes.push(3);
  if (!sameAt<u8>(bytes, otherBytes, 0)) return 1;
  if (sameAt<u8>(bytes, otherBytes, 1)) return 2;
  if (differAt<u8>(bytes, otherBytes, 2)) return 3;
  if (!differAt<u8>(bytes, otherBytes, 1)) return 4;

  let units = Array<u16>.withCapacity(3);
  units.push(300);
  units.push(400);
  units.push(500);
  let otherUnits = Array<u16>.withCapacity(3);
  otherUnits.push(300);
  otherUnits.push(401);
  otherUnits.push(500);
  if (!sameAt<u16>(units, otherUnits, 0)) return 5;
  if (sameAt<u16>(units, otherUnits, 1)) return 6;
  if (differAt<u16>(units, otherUnits, 2)) return 7;
  if (!differAt<u16>(units, otherUnits, 1)) return 8;

  let needle = Array<u8>.withCapacity(2);
  needle.push(2);
  needle.push(3);
  if (find<u8>(bytes, needle) != 1) return 9;
  if (find<u8>(otherBytes, needle) != -1) return 10;
  let unitNeedle = Array<u16>.withCapacity(1);
  unitNeedle.push(500);
  if (find<u16>(units, unitNeedle) != 2) return 11;
  if (find<u16>(otherUnits, units) != -1) return 12;
  console.log("ok");
  return 0;
}
