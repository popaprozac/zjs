// A write to a global name the global object does not own but inherits:
// a setter on its prototype chain runs with the global object as this,
// and a read-only property or a getter-only accessor there refuses the
// write (a TypeError in strict code, silence in sloppy code); a writable
// inherited data property is shadowed by a new global. Each source runs
// as global code through indirect eval.
function run(label, source) {
  let out;
  try { out = (0, eval)(source); } catch (error) { out = error.constructor.name; }
  console.log(label + ": " + out);
}
globalThis.seen = [];
function withInherited(name, descriptor, body) {
  Object.defineProperty(Object.prototype, name, { configurable: true, ...descriptor });
  try { body(); } finally { delete Object.prototype[name]; delete globalThis[name]; }
}
for (const mode of ["", "'use strict'; "]) {
  const tag = mode ? "strict" : "sloppy";
  withInherited("viaSetter", { set(v) { seen.push(v + " " + (this === globalThis)); }, get() { return "getter"; } }, () => {
    seen.length = 0;
    run(tag + " setter", mode + "viaSetter = 5; seen.join() + ' own:' + Object.hasOwn(globalThis, 'viaSetter') + ' ' + viaSetter");
  });
  withInherited("getterOnly", { get() { return "kept"; } }, () => {
    run(tag + " getter only", mode + "getterOnly = 5; 'own:' + Object.hasOwn(globalThis, 'getterOnly') + ' ' + getterOnly");
  });
  withInherited("readOnly", { value: 1, writable: false }, () => {
    run(tag + " read-only", mode + "readOnly = 5; 'own:' + Object.hasOwn(globalThis, 'readOnly') + ' ' + readOnly");
  });
  // Strict code is left out of this one: V8 throws a ReferenceError where
  // the specification (and JavaScriptCore) makes the global.
  if (!mode) withInherited("writable", { value: 1, writable: true }, () => {
    run(tag + " writable", mode + "writable = 5; 'own:' + Object.hasOwn(globalThis, 'writable') + ' ' + writable + ' ' + Object.prototype.writable");
  });
  run(tag + " nowhere", mode + "nowhereAtAll" + tag + " = 5; 'own:' + Object.hasOwn(globalThis, 'nowhereAtAll" + tag + "')");
  withInherited("compound", { set(v) { seen.push("set " + v); }, get() { return 10; } }, () => {
    seen.length = 0;
    run(tag + " compound", mode + "compound += 1; compound++; seen.join()");
  });
}
