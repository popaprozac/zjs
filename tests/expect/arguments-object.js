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

// One whose elements are all data properties takes the class the first
// of its argument count and kind was built with, and is the same as one
// built a property at a time: every case runs again on the kept class.
var out = [];
function plain() { return arguments; }
function strict() { "use strict"; return arguments; }
function two(a, b) { a = "mapped"; return arguments[0]; }
function show(A) {
  var c = Object.getOwnPropertyDescriptor(A, "callee");
  return [A.length, Object.keys(A).join(), typeof c.value + "/" + typeof c.get + "/" + c.enumerable, A[Symbol.iterator] === Array.prototype.values, [...A].join(), JSON.stringify(Object.getOwnPropertyDescriptor(A, "length"))].join(" ");
}
for (var round = 0; round < 3; round++) {
  out.push(show(plain()), show(plain(1, "b")), show(strict(1, "b")), two(1, 2), show(plain(1, "b", 3)));
  try { strict(1, "b").callee; out.push("no throw"); } catch (e) { out.push("strict callee " + e.constructor.name); }
  out.push(plain(7, 8).callee === plain);
}
var wide = []; for (var i = 0; i < 70; i++) wide.push(i);
for (var round = 0; round < 2; round++) { var W = plain.apply(null, wide); out.push([W.length, W[69], Object.keys(W).length, W.callee === plain].join()); }
var a1 = plain(1, 2), a2 = plain(3, 4); a1[0] = "changed"; a1.extra = true; delete a2[1];
out.push([a1[0], a2[0], a2[1], "extra" in a2, Object.keys(a1).join(), Object.keys(a2).join(), a2.length].join(" "));
console.log(out.join("\n"));
