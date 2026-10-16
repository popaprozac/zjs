// A library root that is shareable by construction -- a class whose only
// field is a Mutex -- published through Once, so the generated runtime
// needs no main-thread proof and any host thread may create and use
// contexts. Once<T> currently insists the class be main-bound.
import { Mutex, Once, OnceLifetime } from "std/sync";
import console from "std/console";

struct Registry {
  count: i32;
}

class Engine {
  readonly registry: Mutex<Registry>;
}

const engine = Once<Engine>();

function main(): i32 {
  const lifetime = engine.initialize(new Engine({ registry: Mutex(Registry({ count: 0 })) }));
  const current = engine.get();
  const count = current.registry.withLock((inout registry): i32 => {
    registry.count = registry.count + 1;
    return registry.count;
  });
  if (count != 1) return 1;
  console.log("ok");
  return 0;
}
