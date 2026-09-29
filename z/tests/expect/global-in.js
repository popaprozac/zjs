// `in` and Reflect.has see the builtin globals on the global object, as
// hasOwnProperty does, and so does an object whose chain reaches it.
console.log("undefined" in globalThis, "NaN" in globalThis, "Infinity" in globalThis, "Math" in globalThis, "JSON" in globalThis);
console.log(globalThis.hasOwnProperty("undefined"), globalThis.hasOwnProperty("Math"), "notAGlobal" in globalThis);
console.log(Reflect.has(globalThis, "Math"), Reflect.has(globalThis, "Array"), Reflect.has(globalThis, "missing"));
console.log("parseInt" in globalThis, "globalThis" in globalThis, "toString" in globalThis, "hasOwnProperty" in globalThis);
var child = Object.create(globalThis);
console.log("Math" in child, Reflect.has(child, "Object"), "missing" in child);

// A global made by assignment, and after deleting it.
globalThis.made = 1;
console.log("made" in globalThis);
delete globalThis.made;
console.log("made" in globalThis, typeof globalThis.made);
