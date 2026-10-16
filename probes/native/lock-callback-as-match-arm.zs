// A Mutex.withLock callback with a block body may be a match arm's value.
// zjs_z_compile_to_bytecode returns one from an export c function (G60).
import console from "std/console";
import { Mutex } from "std/sync";

struct State {
  count: u32;
}

class Holder {
  readonly state: Mutex<State>;
}

function found(present: boolean): Option<Holder> {
  if (!present) return Option.none;
  return Option.some(new Holder({ state: Mutex(State({ count: 0 })) }));
}

function counted(present: boolean, extra: usize): usize {
  const holder = found(present);
  return match (holder) {
    some(held) => held.state.withLock((inout state): usize => {
      state.count = state.count + 1;
      let owned = Array<u8>();
      owned.push(1);
      if (extra == 0) return 0;
      return owned.length + extra;
    });
    none => 7;
  };
}

function main(): i32 {
  if (counted(true, 4) != 5 || counted(true, 0) != 0 || counted(false, 4) != 7) return 1;
  console.log("ok");
  return 0;
}
