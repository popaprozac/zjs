// A method may call a function value with `inout this`: the receiver is
// already the mutable reference the callee wants. The engine's runtime
// dispatches every host function this way (`fn(inout this, ...)`). The
// function value is bound first, so only the call is under test.
import console from "std/console";
struct Counter {
  count: i32;
  function apply(inout this, fn: (inout owner: Counter, delta: i32) => i32, delta: i32): i32 {
    return fn(inout this, delta);
  }
}
function add(inout owner: Counter, delta: i32): i32 {
  owner.count = owner.count + delta;
  return owner.count;
}
function main(): i32 {
  let counter = Counter({ count: 1 });
  const adder: (inout owner: Counter, delta: i32) => i32 = add;
  if (counter.apply(adder, 2) != 3) return 1;
  console.log("ok");
  return 0;
}
