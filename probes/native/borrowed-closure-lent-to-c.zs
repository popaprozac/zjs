// A closure that captures an `inout` parameter may be lent to a C function
// whose contract says the callback has a context and lives for the call.
// The engine lends an embedder's host function its way back in like this:
// the closure works on the runtime the interpreter has borrowed.
import console from "std/console";
import lend from "./modules/lend/lend.h";

struct Counter {
  total: i32;
}

function throughC(inout counter: Counter, amount: i32): i32 {
  return lend.probe_lend_twice(amount, (value) => {
    counter.total = counter.total + value;
    return counter.total;
  });
}

function main(): i32 {
  let counter = Counter({ total: 1 });
  // 1 + 5 is 6, and 6 + 6 is 12.
  if (throughC(inout counter, 5) != 12) return 1;
  if (counter.total != 12) return 2;
  console.log("ok");
  return 0;
}
