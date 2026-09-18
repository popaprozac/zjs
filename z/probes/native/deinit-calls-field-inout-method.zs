// A struct's deinit may call an `inout this` method of one of its fields:
// the value is being torn down, so its fields are the deinit's to mutate.
// The engine's runtime releases its regex backend this way. The cleanup
// runs exactly once per value, with and without executor placement.
import console from "std/console";
import { thread } from "std/thread";

// A count kept in C so the probe can observe the deinits from outside.
function releasedCount(delta: i32): i32 = raw c {
  static int released = 0;
  released += delta;
  return released;
}

struct Backend {
  handle: usize;
  function release(inout this): void {
    if (this.handle != 0) {
      const seen = releasedCount(1);
      if (seen < 0) return;
    }
    this.handle = 0;
  }
}
struct Placed {
  backend: Backend;
  deinit on thread.any {
    this.backend.release();
  }
}
struct Plain {
  backend: Backend;
  deinit {
    this.backend.release();
  }
}

function makeAndDrop(): i32 {
  const placed = Placed({ backend: Backend({ handle: 7 }) });
  const plain = Plain({ backend: Backend({ handle: 8 }) });
  return i32(placed.backend.handle + plain.backend.handle);
}

function main(): i32 {
  if (makeAndDrop() != 15) return 1;
  if (releasedCount(0) != 2) return 2;
  const again = makeAndDrop();
  if (again != 15) return 3;
  if (releasedCount(0) != 4) return 4;
  console.log("ok");
  return 0;
}
