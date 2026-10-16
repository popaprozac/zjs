// A named function may be passed directly where a function value is
// wanted. The engine installs every builtin by naming it at the call
// (`method(inout runtime, proto, in name, arrayFlatMap, 1)`), and its
// host-function type takes the runtime by `inout`; a value-only
// signature fails the same way. Binding the function to a typed const
// first and passing that is accepted.
import console from "std/console";
struct Counter {
  count: i32;
}
type Handler = (inout owner: Counter, delta: i32) => i32;
function add(inout owner: Counter, delta: i32): i32 {
  owner.count = owner.count + delta;
  return owner.count;
}
function install(fn: Handler, inout owner: Counter): i32 {
  return fn(inout owner, 2);
}
function main(): i32 {
  let counter = Counter({ count: 1 });
  if (install(add, inout counter) != 3) return 1;
  console.log("ok");
  return 0;
}
