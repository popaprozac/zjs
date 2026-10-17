// Top-level await: a module that awaits finishes before the modules
// waiting on it, and a sibling that does not wait runs meanwhile; import()
// links and evaluates later, as a job, and a failed module throws again;
// import.meta is the module's own.
import { slow } from "./modules/tla-slow.mjs";
import { quick } from "./modules/tla-quick.mjs";
console.log("entry", slow, quick);
console.log(typeof import.meta, Object.getPrototypeOf(import.meta), import.meta.url.startsWith("file:///"),
  import.meta.url.endsWith("/module-top-level-await.mjs"), import.meta === import.meta);
const later = import("./modules/tla-later.mjs");
console.log("import() returned", later instanceof Promise);
const ns = await later;
console.log("later", ns.value, Object.keys(ns).join());
try { await import("./modules/tla-throws.mjs"); } catch (e) { console.log("throws", e.message); }
try { await import("./modules/tla-throws.mjs"); } catch (e) { console.log("again", e.message); }
const again = await import("./modules/tla-later.mjs");
console.log("same namespace", again === ns);
const regex = await /a+/g;
console.log("await /re/", regex.flags);
