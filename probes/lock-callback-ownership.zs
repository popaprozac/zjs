// A Mutex lock callback cannot take ownership of an outer owned value.
//
// Found wiring the ZJS eval entry point: the C ABI receives an owned String,
// the context registry lives behind a Mutex, and the withLock callback
// captures the String as a borrow -- so it cannot pass it on by move, and
// the engine makes an owned copy per call instead.
//
// This probe shows the failure itself: the callback below cannot move the
// captured value on ("cannot move borrowed parameter"). The language
// reference mentions placed `using (move owner)` capture contracts; if that
// applies to withLock callbacks, the ask is documentation and an example,
// not a new feature.
import console from "std/console";
import { Mutex } from "std/sync";

struct Store {
  items: Array<String>;
}

function stash(inout store: Store, text: String): void {
  store.items.push(move text);
}

function main(): i32 {
  const guarded = Mutex(Store({ items: Array<String>() }));
  const owned: String = "payload";
  guarded.withLock((inout store): void => {
    stash(inout store, move owned);
  });
  const count = guarded.withLock((in store): usize => store.items.length);
  if (count != 1) return 1;
  console.log("ok");
  return 0;
}
