// Converting between f64 and decimal text in Z itself, independent of the
// C library's locale: the shortest digits that round-trip a value, and a
// correctly rounded parse of a decimal literal from bytes. The engine
// needs both for every number it prints or reads (ToString(Number),
// ToNumber of a string, numeric literals, JSON, toFixed and its kin) and
// today gets them from snprintf and strtod, which follow the host's
// LC_NUMERIC: an embedder in a comma-decimal locale reads 1.25 as 1 and
// prints 0.1 as "0,1". Z's own interpolation and JSON use the same calls.
//
// The names and shapes below are a proposal only: digits and a decimal
// exponent rather than a finished layout, since JavaScript, JSON, and Z's
// own interpolation lay the digits out differently.
import console from "std/console";
import { shortestDecimal, parseDecimal } from "std/number";

function main(): i32 {
  // 0.1 is the digits "1" with the point one place to the left.
  const tenth = shortestDecimal(0.1);
  if (tenth.digits != "1" || tenth.exponent != -1) return 1;
  // 2^63's shortest digits, not its 19 exact ones.
  const big = shortestDecimal(9223372036854775808.0);
  if (big.digits != "9223372036854776" || big.exponent != 3) return 2;
  let text = Array<u8>();
  text.push(49);
  text.push(46);
  text.push(50);
  text.push(53);
  // "1.25", whatever the host's locale.
  if (parseDecimal(text) != 1.25) return 3;
  console.log("ok");
  return 0;
}
