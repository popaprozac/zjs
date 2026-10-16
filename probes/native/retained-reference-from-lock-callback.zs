// A class instance stored in a registry behind a Mutex stays alive while
// it is stored: handing a caller a retained reference from inside the
// lock callback (matching the stored Option and returning `some` of it)
// adds a reference, and the caller dropping that reference takes it away
// again. The engine's context registry admits every ABI call this way.
import console from "std/console";
import { Mutex } from "std/sync";

// A count kept in C so the probe can see when the instance is destroyed.
function destroyedCount(delta: i32): i32 = raw c {
  static int destroyed = 0;
  destroyed += delta;
  return destroyed;
}

struct Tracker {
  value: i32;
  deinit {
    const seen = destroyedCount(1);
    if (seen < 0) console.log("unreachable");
  }
}

class Item {
  readonly tracker: Tracker;
}

struct Registry {
  slots: Array<Option<Item>>;
}

function retainAt(in registry: Mutex<Registry>, at: usize): Option<Item> {
  return registry.withLock((in slots): Option<Item> => {
    if (at >= slots.slots.length) return Option<Item>.none;
    match (slots.slots[at]) {
      some(item) => {
        return Option<Item>.some(item);
      }
      none => {
        return Option<Item>.none;
      }
    }
  });
}

function valueAt(in registry: Mutex<Registry>, at: usize): i32 {
  match (retainAt(in registry, at)) {
    some(item) => {
      return item.tracker.value;
    }
    none => {
      return -1;
    }
  }
}

function main(): i32 {
  const registry = Mutex(Registry({ slots: Array<Option<Item>>() }));
  const item = new Item({ tracker: Tracker({ value: 7 }) });
  registry.withLock((inout slots): void => {
    slots.slots.push(Option<Item>.some(item));
  });
  if (valueAt(in registry, 0) != 7) return 1;
  if (destroyedCount(0) != 0) return 2;
  if (valueAt(in registry, 0) != 7) return 3;
  if (destroyedCount(0) != 0) return 4;
  console.log("ok");
  return 0;
}
