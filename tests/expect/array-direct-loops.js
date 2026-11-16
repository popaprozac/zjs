// indexOf, lastIndexOf, includes, slice, concat, and reverse read an
// array's elements in place. Everything that is not a present data
// element must still go the long way: a hole (which the prototypes may
// fill), an accessor (which may change the array as it runs), a
// read-only element, and a receiver that is no array at all.
var log = [];
function note() { var parts = []; for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i])); log.push(parts.join(" ")); }
function show(list) { var parts = []; for (var i = 0; i < list.length; i++) parts.push(i in list ? String(list[i]) : "-"); return "[" + parts.join(",") + "]"; }
function caught(run) { try { return run(); } catch (error) { return error.constructor.name; } }

// --- what is equal ---
var object = {}, mixed = [1, 2.5, "two", object, null, undefined, NaN, -0, true, "t" + "wo", 1.0, 7];
note("indexOf:", mixed.indexOf(1), mixed.indexOf(2.5), mixed.indexOf("two"), mixed.indexOf(object), mixed.indexOf(null), mixed.indexOf(undefined), mixed.indexOf(NaN), mixed.indexOf(0), mixed.indexOf(true), mixed.indexOf({}), mixed.indexOf(7), mixed.indexOf("7"));
note("lastIndexOf:", mixed.lastIndexOf(1), mixed.lastIndexOf("two"), mixed.lastIndexOf(NaN), mixed.lastIndexOf(0), mixed.lastIndexOf(undefined), mixed.lastIndexOf(8));
note("includes:", mixed.includes(1), mixed.includes(NaN), mixed.includes(0), mixed.includes("two"), mixed.includes({}), mixed.includes(undefined), mixed.includes(8), [1.5, 2].includes(2), [1, 2].includes(2.0), [0.5 + 0.5].indexOf(1));
note("from an index:", mixed.indexOf(1, 1), mixed.indexOf(1, -2), mixed.indexOf(1, 99), mixed.indexOf(1, -99), mixed.lastIndexOf(1, 5), mixed.lastIndexOf(1, -3), mixed.lastIndexOf(1, -99), mixed.includes(1, 11), mixed.includes(7, -1), [].indexOf(1), [].includes(undefined), [].lastIndexOf(1));

// --- holes, alone and filled by a prototype ---
var holed = [1, , 3, , 5];
note("holes:", holed.indexOf(undefined), holed.lastIndexOf(undefined), holed.includes(undefined), holed.indexOf(3), holed.lastIndexOf(5), show(holed.slice()), show(holed.slice(1, 4)), show(holed.concat([, 9])), show([, 1, , 2].reverse()), show([1, , 3].reverse()), show([, , 7, 8].reverse()));
Array.prototype[1] = "filled";
note("a prototype fills them:", holed.indexOf("filled"), holed.lastIndexOf("filled"), holed.includes("filled"), holed.indexOf(undefined), show(holed.slice()), holed.slice().hasOwnProperty(1), holed.concat().hasOwnProperty(1), show([1, , 3].reverse()), show([9, , 8, 7].reverse()), show([5, , ].reverse()), show([4, , 6, , ].reverse()));
delete Array.prototype[1];
Object.prototype[3] = "from Object.prototype";
note("and further up:", holed.indexOf("from Object.prototype"), holed.includes("from Object.prototype"), show(holed.slice(2)), show(holed.concat().slice(3)));
delete Object.prototype[3];
note("gone again:", holed.indexOf("filled"), show(holed.slice()), holed.slice().hasOwnProperty(1));

// --- accessors, and an array that changes as it is read ---
var shrinking = [1, 2, 3, 4, 5, 6];
Object.defineProperty(shrinking, 1, { get: function () { shrinking.length = 3; return "got"; }, configurable: true });
note("a getter that shortens:", shrinking.indexOf(6), show(shrinking));
var growing = [1, 2, 3];
Object.defineProperty(growing, 0, { get: function () { growing.push("late"); return 1; }, configurable: true });
note("a getter that lengthens:", growing.indexOf("late"), growing.includes("late"), growing.length);
var swapping = [0, 1, 2, 3];
Object.defineProperty(swapping, 0, { get: function () { swapping[3] = "changed"; return 0; }, configurable: true });
note("a getter that changes a later one:", swapping.lastIndexOf(3), swapping.indexOf("changed"), swapping.includes(3), show(swapping.slice(1)), show(swapping.concat()));
var reads = [];
var watched = [10, 20, 30];
Object.defineProperty(watched, 1, { get: function () { reads.push("get"); return 20; }, set: function (v) { reads.push("set " + v); }, configurable: true, enumerable: true });
note("an accessor in a slice and a concat:", show(watched.slice()), show(watched.concat([1])), reads.join());
reads = [];
watched.reverse();
note("in a reverse:", reads.join(), watched[0], watched[2]);
var paired = [1, 2, 3, 4, 5];
Object.defineProperty(paired, 4, { get: function () { paired[1] = "moved"; return 5; }, set: function (v) { reads.push("set " + v); }, configurable: true });
reads = [];
paired.reverse();
note("a getter that changes one not yet swapped:", show(paired.slice(0, 4)), reads.join());

// --- elements that may not be written ---
var frozen = Object.freeze([1, 2, 3]);
note("frozen:", frozen.indexOf(3), frozen.includes(2), show(frozen.slice()), show(frozen.concat(frozen)), caught(function () { return frozen.reverse(); }), show(frozen));
var sealed = Object.seal([1, 2, 3]);
note("sealed:", show(sealed.reverse()), sealed.lastIndexOf(1));
var half = [1, 2, 3, 4];
Object.defineProperty(half, 3, { value: 4, writable: false, configurable: true });
note("one read-only element:", caught(function () { return half.reverse(); }), show(half), half.indexOf(4), show(half.slice(2)));
var closed = Object.preventExtensions([1, , 3]);
note("no new elements:", caught(function () { return show(closed.reverse()); }), show(closed));

// --- receivers that are not arrays ---
var like = { length: 4, 0: "a", 1: "b", 3: "d" };
note("an array-like:", Array.prototype.indexOf.call(like, "d"), Array.prototype.lastIndexOf.call(like, "a"), Array.prototype.includes.call(like, undefined), show(Array.prototype.slice.call(like)), show(Array.prototype.concat.call(like, [1])[0] === like ? ["itself"] : []), show(Array.prototype.reverse.call({ length: 3, 0: "x", 2: "z" })), Array.prototype.indexOf.call("text", "x"), Array.prototype.includes.call("text", "e"));
(function () { note("arguments:", Array.prototype.indexOf.call(arguments, 3), Array.prototype.includes.call(arguments, 2), show(Array.prototype.slice.call(arguments, 1)), show(Array.prototype.reverse.call(arguments))); })(1, 2, 3);
var named = [1, 2, 3];
named.extra = "named";
named["7"] = 8;
note("an array with more on it:", named.indexOf(8), named.lastIndexOf(8), show(named.slice(2)), named.slice().extra, show(named.concat()), show(named.reverse()), named.extra);

// --- what slice and concat make ---
function Marked() { var made = []; made.marked = true; return made; }
var marking = [1, 2, 3, 4];
marking.constructor = { [Symbol.species]: Marked };
note("a species of its own:", marking.slice(1).marked, show(marking.slice(1)), marking.concat([5]).marked, show(marking.concat([5], 6)), show(marking.reverse()), marking.reverse() === marking, marking.indexOf(4), [1].slice().marked);
var same = [1, 2, 3, 4];
same.constructor = { [Symbol.species]: function () { return same; } };
note("the same array as its result:", show(same.slice(1)), show(same));
var plainResult = [5, 6, 7];
plainResult.constructor = { [Symbol.species]: function (n) { return { made: n }; } };
var sliced = plainResult.slice(1);
note("a result that is no array:", sliced.made, sliced[0], sliced[1], sliced.length, Array.isArray(sliced));
var spreadable = { length: 2, 0: "s0", 1: "s1" };
spreadable[Symbol.isConcatSpreadable] = true;
var closedArray = [1, 2];
closedArray[Symbol.isConcatSpreadable] = false;
note("concat:", show([0].concat(spreadable)), [0].concat(closedArray).length, [0].concat(closedArray)[1] === closedArray, show([].concat(1, [2, [3]], "four", [, 6])), show([1, 2].concat()), [1, 2].concat() === undefined);

// --- reverse ---
note("reverse:", show([].reverse()), show([1].reverse()), show([1, 2].reverse()), show([1, 2, 3].reverse()), show(["a", { }, null, undefined, 2.5].reverse()), show([1, 2, 3, 4, 5, 6, 7, 8, 9].reverse()));
var long = [];
for (var n = 0; n < 200; n++) long.push(n % 2 ? n : "s" + n);
var copy = long.slice();
long.reverse();
var mirrored = true;
for (var m = 0; m < 200; m++) if (long[m] !== copy[199 - m]) mirrored = false;
note("two hundred:", mirrored, long.indexOf(199), long.indexOf("s0"), long.lastIndexOf(1), long.includes("s198"), long.indexOf("s199"), copy.concat(long).length, copy.concat(long).lastIndexOf("s0"), copy.slice(-3).join(), copy.slice(50, 53).join());

console.log(log.join("\n"));
