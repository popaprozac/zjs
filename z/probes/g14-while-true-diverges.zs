// G14 — `while (true)` recognized as diverging.  STATUS: open
//
// This is the shape of every bytecode interpreter loop. Today it reports
// "function must end with a return value" and needs an unreachable trailing
// return.
import console from "std/console";

function run(limit: i32): i32 {
  let index = 0;
  while (true) {
    if (index >= limit) return index;
    index = index + 1;
  }
}

function main(): i32 {
  if (run(3) != 3) return 1;
  console.log("g14 ok");
  return 0;
}
