// A result may be bound to a name that is never read, and the same name
// may be bound again later in the function. The engine's Array.prototype
// pop and shift bind `ok` in an early-return block and again afterwards.
// Either binding alone is accepted; the pair is not: the unused first
// binding reaches the C compiler without the unused attribute the
// emitter gives an unused binding, and -Werror rejects it.
import console from "std/console";
struct State {
  flag: boolean;
  function set(inout this): boolean {
    this.flag = true;
    return this.flag;
  }
}
function touch(inout state: State, early: boolean): i32 {
  if (early) {
    const ok = state.set();
    return 1;
  }
  let ok = state.set();
  if (ok) {
    ok = false;
    return 2;
  }
  return 3;
}
function main(): i32 {
  let state = State({ flag: false });
  if (touch(inout state, true) != 1 || !state.flag) return 1;
  if (touch(inout state, false) != 2) return 2;
  console.log("ok");
  return 0;
}
