// A class instance built outside a Mutex lock callback, stored into the
// protected state by that callback, then removed and dropped, must be
// destroyed. It is not: the callback's capture of the reference is never
// released, so the instance outlives every named owner.
import { Mutex } from "std/sync";
import console from "std/console";

class Item {
  readonly label: i32;
}

struct Store {
  items: Array<Option<Item>>;
}

function main(): i32 {
  let store = Mutex(Store({ items: Array<Option<Item>>() }));
  const item = new Item({ label: 7 });
  const watch = weak item;
  store.withLock((inout state): void => {
    state.items.push(Option<Item>.some(item));
  });
  store.withLock((inout state): void => {
    state.items[0] = Option<Item>.none;
  });
  // `item` is the last named owner; after this block nothing holds it.
  {
    const last = item;
  }
  let alive = false;
  match (attempt watch.upgrade()) {
    success(strong) => {
      alive = true;
    }
    failure(expired) => {
      alive = false;
    }
  }
  if (alive) {
    console.log("still alive: the lock callback's capture was never released");
    return 1;
  }
  console.log("ok");
  return 0;
}
