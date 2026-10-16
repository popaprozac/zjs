// A class instance built outside a Mutex lock callback, stored into the
// protected state by that callback, removed again, and dropped by its
// last owner must be destroyed. The helper owns every strong reference,
// so after it returns only the weak one remains -- and it still
// upgrades.
import { Mutex } from "std/sync";
import console from "std/console";

class Item {
  readonly label: i32;
}

struct Store {
  items: Array<Option<Item>>;
}

// Construct, insert through the callback, remove; hand back a weak
// reference only.
function buildInsertRemove(inout store: Mutex<Store>): Weak<Item> {
  const item = new Item({ label: 7 });
  const watch = weak item;
  store.withLock((inout state): void => {
    state.items.push(Option<Item>.some(item));
  });
  store.withLock((inout state): void => {
    state.items[0] = Option<Item>.none;
  });
  return watch;
}

function main(): i32 {
  let store = Mutex(Store({ items: Array<Option<Item>>() }));
  const watch = buildInsertRemove(inout store);
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
    console.log("still alive after every strong owner dropped");
    return 1;
  }
  console.log("ok");
  return 0;
}
