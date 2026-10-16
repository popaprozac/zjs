// An Option of a function value read out of a field, as a plain function
// value is (G59): a hook that may be absent, called with the struct that
// holds it.
import console from "std/console";

type Step = (x: i32) => i32;

function twice(x: i32): i32 {
  return x * 2;
}

struct Holder {
  maybe: Option<Step> = Option<Step>.none;
}

function viaOption(in holder: Holder): i32 {
  const step = holder.maybe;
  return match (step) {
    some(call) => call(3);
    none => 0;
  };
}

function main(): i32 {
  let holder = Holder({});
  holder.maybe = Option.some(twice);
  if (viaOption(in holder) != 6) return 1;
  console.log("ok");
  return 0;
}
