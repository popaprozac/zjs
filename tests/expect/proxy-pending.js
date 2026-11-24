// Proxy, what is refused until its internal methods are written: `new
// Proxy` throws a TypeError for a target that is a function (apply and
// construct) and for a handler that has one of the seven traps below.
// The specification accepts every one of these; the expectation is this
// engine's, not node's, and each line goes when its trap lands.
function show(label, body) {
  let out;
  try { out = typeof body(); } catch (error) { out = error.constructor.name; }
  console.log(label + ": " + out);
}
show("function target", () => new Proxy(function () {}, {}));
show("arrow target", () => new Proxy(() => 1, {}));
show("class target", () => new Proxy(class {}, {}));
show("builtin target", () => new Proxy(Math.max, {}));
show("revocable function target", () => Proxy.revocable(function () {}, {}));
for (const name of ["getOwnPropertyDescriptor", "defineProperty", "ownKeys", "getPrototypeOf", "setPrototypeOf", "isExtensible", "preventExtensions"]) {
  show(name, () => new Proxy({}, { [name]() {} }));
  show(name + " inherited", () => new Proxy({}, Object.create({ [name]() {} })));
  show(name + " null", () => new Proxy({}, { [name]: null }));
  show(name + " undefined", () => new Proxy({}, { [name]: undefined }));
}
// Traps only a function's proxy has are not looked at for an object's.
show("apply on an object target", () => new Proxy({}, { apply() {} }));
show("construct on an object target", () => new Proxy({}, { construct() {} }));
// A prototype chain that would come back to an object through a proxy
// for it is refused: until the getPrototypeOf trap, a proxy hands the
// prototype question to its target, and such a chain would never end.
function attempt(label, body) {
  let out;
  try { out = body(); } catch (error) { out = error.constructor.name; }
  console.log(label + ": " + out);
}
attempt("cycle through its own proxy", () => { const t = {}; Object.setPrototypeOf(t, new Proxy(t, {})); return "set"; });
attempt("cycle through two proxies", () => { const a = {}, b = {}; Object.setPrototypeOf(a, new Proxy(b, {})); Object.setPrototypeOf(b, new Proxy(a, {})); return "set"; });
attempt("cycle, Reflect", () => { const t = {}; return Reflect.setPrototypeOf(t, new Proxy(new Proxy(t, {}), {})); });
attempt("no cycle", () => { const t = {}; Object.setPrototypeOf(t, new Proxy({ up: 1 }, {})); return t.up; });
