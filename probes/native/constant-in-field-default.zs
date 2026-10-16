// A struct field's default may name a module constant. The runtime starts
// its interrupt countdown at INTERRUPT_POLL_INTERVAL this way.
import console from "std/console";

const LIMIT: u32 = 4096;

struct Counter {
  name: u32;
  left: u32 = LIMIT;
}

function main(): i32 {
  const counter = Counter({ name: 1 });
  if (counter.left != 4096) return 1;
  console.log("ok");
  return 0;
}
