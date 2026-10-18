// An arguments object is an ordinary object, not an array: its elements,
// a writable and configurable length, @@iterator, and callee. A sloppy
// function with simple parameters maps its elements to the parameters
// both ways, until an element is deleted or redefined read-only; a strict
// function's, or one with defaults, rest, or patterns, maps nothing, and
// its callee throws.
var out = [];
function f(a, b) { arguments[0] = "set"; b = "param"; out.push(a, arguments[1], arguments.length); return arguments; }
var A = f(1, 2);
out.push(Object.keys(A).join(), JSON.stringify(Object.getOwnPropertyDescriptor(A, "length")), A.callee === f);
out.push(Object.getPrototypeOf(A) === Object.prototype, Array.isArray(A), A instanceof Array, "push" in A, JSON.stringify(A));
out.push(Object.prototype.toString.call(A), A[Symbol.iterator] === Array.prototype.values, [...A].join());
out.push(JSON.stringify(Object.getOwnPropertyDescriptor(A, "0")));
function g(a) { "use strict"; arguments[0] = 9; return [a, arguments.length]; }
out.push(g(1).join());
try { (function () { "use strict"; return arguments.callee; })(); } catch (e) { out.push("strict callee " + e.constructor.name); }
function d(a = 0, b) { arguments[1] = "unmapped"; return b; }
out.push(d(1, 2));
function h() { arguments.length = 1; return Array.prototype.slice.call(arguments).join() + "|" + [...arguments].join(); }
out.push(h(1, 2, 3));
function m(a) { delete arguments[0]; arguments[0] = 5; return a; }
out.push(m(1));
function r(a) { Object.defineProperty(arguments, "0", { value: "defined" }); var before = a; Object.defineProperty(arguments, "0", { writable: false }); a = "later"; return [before, arguments[0]].join(); }
out.push(r(1));
function dup(a, a) { arguments[0] = "first"; arguments[1] = "second"; return a; }
out.push(dup(1, 2));
function grow(a) { arguments[3] = 4; return arguments.length + "," + arguments[3]; }
out.push(grow(1));
out.push((function () { return Object.isFrozen(Object.getOwnPropertyDescriptor((function () { "use strict"; return arguments; })(), "callee").get); })());
console.log(out.join("\n"));
