// A name no declaration made is the global object's property: its own,
// an accessor on it, or one on its [[Prototype]] chain (Object.prototype's
// toString, a property added there, a setter there that a sloppy write
// runs); a write with none anywhere makes a global.
var out = [];
out.push(typeof toString, typeof hasOwnProperty, toString === Object.prototype.toString, typeof notThere);
try { notThere; } catch (e) { out.push(e.constructor.name); }
Object.defineProperty(globalThis, "viaAccessor", { get() { return "got"; }, set(v) { out.push("set " + v); }, configurable: true });
out.push(viaAccessor, typeof viaAccessor);
viaAccessor = 3;
Object.prototype.inheritedProp = "inherited";
out.push(inheritedProp, typeof inheritedProp);
Object.defineProperty(Object.prototype, "inheritedSetter", { set(v) { out.push("proto setter " + v); }, configurable: true });
inheritedSetter = 7;
out.push(Object.prototype.hasOwnProperty.call(globalThis, "inheritedSetter"));
globalThis.later = "own";
out.push(typeof later, later);
plainNew = 1; out.push(plainNew, globalThis.plainNew);
console.log(out.join(" | "));
