// Inside a generic function over Array<T>, an integer literal takes the
// element type where an element is wanted: pushed into an Array<T>, and
// compared with an element. Every instantiation the program makes is of
// an integer T. The engine's replacement-pattern expansion serves the
// Latin-1 and UTF-16 paths with one body that pushes `$` (36) and
// compares elements with `$`, `&`, and digits.
import console from "std/console";

function dollarsOf<T>(in source: Array<T>): Array<T> {
  let found = Array<T>();
  let k: usize = 0;
  while (k < source.length) {
    if (source[k] == 36) {
      found.push(36);
    }
    k = k + 1;
  }
  return found;
}

function main(): i32 {
  let bytes = Array<u8>.withCapacity(3);
  bytes.push(36);
  bytes.push(65);
  bytes.push(36);
  const dollars = dollarsOf<u8>(bytes);
  if (dollars.length != 2 || dollars[1] != 36) return 1;
  let units = Array<u16>.withCapacity(2);
  units.push(300);
  units.push(36);
  const unitDollars = dollarsOf<u16>(units);
  if (unitDollars.length != 1 || unitDollars[0] != 36) return 2;
  console.log("ok");
  return 0;
}
