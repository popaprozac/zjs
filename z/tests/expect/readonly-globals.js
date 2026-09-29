// NaN, Infinity, and undefined are read-only globals: sloppy writes leave
// them as they were, strict ones throw, and `undefined` is an ordinary
// name a function may bind for itself.
var out = [];
function show() { out.push(Array.prototype.join.call(arguments, " ")); }
NaN = 2; Infinity = 3; undefined = 4;
show(NaN, Infinity, undefined, typeof undefined);
var r = (NaN = 9); show(r, NaN);
undefined++; Infinity += 1; show(undefined, Infinity);
[undefined] = [1]; ({ a: NaN } = { a: 5 }); show(undefined, NaN);
globalThis.NaN = 5; globalThis.undefined = 6; show(NaN, undefined);
show(Object.getOwnPropertyDescriptor(globalThis, "NaN").writable, delete globalThis.undefined);
function local() { var undefined = 5; undefined = 6; return undefined; }
function param(undefined) { return undefined; }
function shadowLet() { let undefined = "shadow"; return undefined; }
show(local(), param(7), shadowLet(), void 0 === undefined);
var o = { undefined: 1 }; show(o.undefined, o["undefined"]);
function strictWrite() { "use strict"; try { NaN = 1; } catch (e) { return e.constructor.name; } return "no throw"; }
function strictUndef() { "use strict"; try { undefined = 1; } catch (e) { return e.constructor.name; } return "no throw"; }
show(strictWrite(), strictUndef());
var x; show(x === undefined, typeof x === "undefined");
console.log(out.join("\n"));
