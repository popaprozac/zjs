// A function value may be called inside a lock's callback, with storage the
// lock guards. The engine installs its optional builtins this way: the
// installer is a function value, called with the context's runtime while
// the context's lock is held.
import console from "std/console";
import { Mutex } from "std/sync";

struct Runtime {
  count: u32;
}

struct State {
  runtime: Runtime;
}

function installThing(inout runtime: Runtime): void {
  runtime.count = runtime.count + 1;
}

function installInto(in state: Mutex<State>, install: (inout runtime: Runtime) => void): void {
  state.withLock((inout locked): void => {
    install(inout locked.runtime);
  });
}

function main(): i32 {
  const state = Mutex(State({ runtime: Runtime({ count: 0 }) }));
  installInto(in state, installThing);
  installInto(in state, installThing);
  if (state.withLock((in locked): u32 => locked.runtime.count) != 2) return 1;
  console.log("ok");
  return 0;
}
