// A struct's deinit may call an `inout this` method of one of its fields:
// the value is being torn down, so its fields are the deinit's to mutate.
import console from "std/console";
import { thread } from "std/thread";
struct Backend {
  handle: usize;
  function release(inout this): void {
    this.handle = 0;
  }
}
struct Owner {
  backend: Backend;
  deinit on thread.any {
    this.backend.release();
  }
}
function main(): i32 {
  const owner = Owner({ backend: Backend({ handle: 7 }) });
  if (owner.backend.handle != 7) return 1;
  console.log("ok");
  return 0;
}
