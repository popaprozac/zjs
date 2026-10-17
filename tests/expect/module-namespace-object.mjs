// A namespace's exports read as writable, enumerable, non-configurable
// data properties holding the binding's value; nothing about them can be
// changed, and one still uninitialized throws wherever it is read.
import * as self from "./module-namespace-object.mjs";
const show = (f) => { try { return String(f()); } catch (e) { return e.constructor.name; } };
console.log(show(() => Object.keys(self)));
console.log(show(() => Object.prototype.hasOwnProperty.call(self, "later")));
console.log(show(() => { for (const k in self) {} return "listed"; }));
console.log(show(() => "later" in self), show(() => Reflect.ownKeys(self).length));
export let later = 1;
export const fixed = "f";
export function fn() {}
console.log(JSON.stringify(Object.getOwnPropertyDescriptor(self, "later")));
console.log(Object.keys(self).join(","), JSON.stringify(self));
console.log(Reflect.defineProperty(self, "later", { value: 1 }), Reflect.defineProperty(self, "later", { value: 2 }));
console.log(Reflect.defineProperty(self, "later", { writable: false }), Reflect.defineProperty(self, "fresh", { value: 1 }));
console.log(show(() => Object.freeze(self)), Object.isFrozen(self), Object.isSealed(self), Object.isExtensible(self));
console.log(Reflect.set(self, "later", 5), Reflect.deleteProperty(self, "later"), Reflect.deleteProperty(self, "absent"));
console.log(Reflect.setPrototypeOf(self, null), Reflect.setPrototypeOf(self, {}), self[Symbol.toStringTag]);
later = 2;
console.log(self.later, Object.entries(self).map(([k, v]) => k + "=" + typeof v).join(" "));
