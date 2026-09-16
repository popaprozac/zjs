// A ternary of integer literals used as an operand of `usize` arithmetic
// should take the operand's type, as a bare literal does.
import console from "std/console";
function main(): i32 {
  let index: usize = 0;
  const wide = true;
  index = index + (wide ? 2 : 1);
  index = index + 3;
  if (index != 5) return 1;
  console.log("ok");
  return 0;
}
