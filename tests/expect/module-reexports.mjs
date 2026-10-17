// Re-exports: star exports pass on every name but default, a name two
// stars give differently is left out, and namespaces nest.
import * as hub from "./modules/hub.mjs";
import { a, renamed, sourceDefault, passedOn, sourceSpace, otherSpace, "string name" as fromString } from "./modules/hub.mjs";
console.log(Object.keys(hub).join(","));
console.log(a, renamed, sourceDefault, passedOn, fromString);
console.log("b" in hub, "default" in hub, hub.c);
console.log(Object.keys(sourceSpace).join(","), sourceSpace.default, otherSpace.b);
console.log(sourceSpace === hub.sourceSpace);
export default class {}
import Self from "./module-reexports.mjs";
console.log(typeof Self, Self.name);
