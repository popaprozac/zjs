// Imports are live bindings of the exporting module, read as they are.
import { count, bump, double as twice, later } from "./modules/counter.mjs";
import makeDefault from "./modules/counter.mjs";
import * as counter from "./modules/counter.mjs";

console.log(count, twice(21), makeDefault(), makeDefault.name, later);
bump();
bump();
console.log(count, counter.count, counter.default === makeDefault);
console.log(Object.keys(counter).join(","));
console.log(Object.prototype.toString.call(counter), Object.getPrototypeOf(counter), Object.isExtensible(counter));
console.log(typeof count, typeof counter, "count" in counter, "missing" in counter);
try { count = 5; } catch (e) { console.log(e.constructor.name); }
try { counter.count = 5; } catch (e) { console.log(e.constructor.name); }
try { counter.fresh = 1; } catch (e) { console.log(e.constructor.name); }
try { delete counter.count; } catch (e) { console.log(e.constructor.name); }
console.log(count, this, (function () { return this; })());
try { undeclared = 1; } catch (e) { console.log(e.constructor.name); }
