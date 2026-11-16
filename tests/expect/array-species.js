// slice, concat, map, filter, splice, flat, and flatMap make their
// result through the array's species. For an ordinary array nothing a
// program could observe is read to find it; every way a program can
// change the answer must still be seen, and seen in the order the
// specification reads things.
var log = [];
function note() { var parts = []; for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i])); log.push(parts.join(" ")); }
function caught(run) { try { return run(); } catch (error) { return error.constructor.name; } }
var isArray = Array.isArray, arrayPrototype = Array.prototype;
function kind(result) { return (isArray(result) ? "array" : typeof result) + (result && result.marked ? " marked" : "") + (result && Object.getPrototypeOf(result) === arrayPrototype ? "" : " other-prototype"); }
function all(list) {
  return [kind(list.slice(1)), kind(list.concat([9])), kind(list.map(function (x) { return x; })), kind(list.filter(function () { return true; })), kind(list.slice().splice(0, 1)), kind(list.flat()), kind(list.flatMap(function (x) { return [x]; }))].join();
}
function Marked(n) { var made = []; made.marked = true; return made; }

// --- ordinary arrays ---
var plain = [1, 2, 3];
note("plain:", all(plain), plain.slice(1).join(), plain.map(function (x) { return x * 2; }).join(), plain.concat(4, [5]).join(), [1, [2, [3]]].flat().length);
note("empty and long:", [].slice().length, [].map(function () {}).length, kind(new Array(5).slice()), new Array(5).slice().length, new Array(70000).slice(69999).length);

// --- the array's own constructor ---
var own = [1, 2, 3];
own.constructor = { [Symbol.species]: Marked };
note("an own constructor:", all(own));
own.constructor = undefined;
note("undefined:", all(own));
own.constructor = { [Symbol.species]: null };
note("a null species:", all(own));
own.constructor = {};
note("no species:", all(own));
own.constructor = 5;
note("not an object:", caught(function () { return all(own); }));
own.constructor = { [Symbol.species]: 5 };
note("a species that is no constructor:", caught(function () { return all(own); }));
delete own.constructor;
note("deleted:", all(own));
own.tag = "named";
note("another property of its own:", all(own), own.slice().tag);

// --- Array.prototype.constructor ---
var saved = Array.prototype.constructor;
Array.prototype.constructor = { [Symbol.species]: Marked };
note("replaced on the prototype:", all(plain), all([4, 5]));
Array.prototype.constructor = undefined;
note("undefined there:", all(plain));
var reads = [];
Object.defineProperty(Array.prototype, "constructor", { get: function () { reads.push("constructor"); return saved; }, configurable: true });
note("a getter there:", kind(plain.slice()), kind(plain.map(function (x) { return x; })), reads.join());
Object.defineProperty(Array.prototype, "constructor", { value: saved, writable: true, configurable: true });
note("restored:", all(plain));
delete Array.prototype.constructor;
note("deleted there:", all(plain), [].constructor === Object);
Array.prototype.constructor = saved;
note("put back:", all(plain), [].constructor === Array);

// --- Array[Symbol.species] ---
var speciesGetter = Object.getOwnPropertyDescriptor(Array, Symbol.species).get;
reads = [];
Object.defineProperty(Array, Symbol.species, { get: function () { reads.push("species"); return Marked; }, configurable: true });
note("another species:", all(plain), reads.length);
reads = [];
Object.defineProperty(Array.prototype, "constructor", { get: function () { reads.push("constructor"); return saved; }, configurable: true });
plain.slice();
note("the order of the reads:", reads.join());
Object.defineProperty(Array.prototype, "constructor", { value: saved, writable: true, configurable: true });
Object.defineProperty(Array, Symbol.species, { value: undefined, configurable: true });
note("undefined as a value:", all(plain));
Object.defineProperty(Array, Symbol.species, { value: Marked, configurable: true });
note("a constructor as a value:", all(plain));
delete Array[Symbol.species];
note("deleted:", all(plain));
Object.defineProperty(Array, Symbol.species, { get: speciesGetter, configurable: true });
note("the first getter again:", all(plain), Array[Symbol.species] === Array);

// --- another prototype ---
var moved = [1, 2, 3];
Object.setPrototypeOf(moved, { constructor: { [Symbol.species]: Marked }, slice: Array.prototype.slice, map: Array.prototype.map });
note("another prototype:", kind(moved.slice()), kind(moved.map(function (x) { return x; })), kind(Array.prototype.concat.call(moved, [1])), kind(Array.prototype.filter.call(moved, function () { return true; })));
Object.setPrototypeOf(moved, Array.prototype);
note("and back:", all(moved));
var bare = [1, 2];
Object.setPrototypeOf(bare, null);
note("none:", kind(Array.prototype.slice.call(bare)), kind(Array.prototype.map.call(bare, function (x) { return x; })));

// --- Array.prototype changing shape around its constructor ---
Array.prototype.extra = function () { return "extra"; };
note("a method added:", all(plain), plain.extra());
Array.prototype.constructor = { [Symbol.species]: Marked };
note("then the constructor replaced:", all(plain));
Array.prototype.constructor = saved;
delete Array.prototype.extra;
note("both undone:", all(plain));
for (var k = 0; k < 80; k++) Array.prototype["crowd" + k] = k;
note("a crowded prototype:", all(plain), plain.crowd79);
Array.prototype.constructor = { [Symbol.species]: Marked };
note("its constructor replaced:", all(plain));
Array.prototype.constructor = saved;
note("and restored:", all(plain));
for (var k2 = 0; k2 < 80; k2++) delete Array.prototype["crowd" + k2];
note("uncrowded:", all(plain), [5, 6, 7].slice(1).join(), "crowd3" in plain);

// --- not arrays, and the global ---
note("array-likes:", kind(Array.prototype.slice.call({ length: 2, 0: "a", 1: "b" })), kind(Array.prototype.map.call("ab", function (x) { return x; })), kind(Array.prototype.concat.call(5, 6)));
var KeptArray = Array;
Array = function Other() { return { other: true }; };
note("the global replaced:", all(plain), [1, 2].slice().length, KeptArray.isArray([].concat()));
Array = KeptArray;
note("and put back:", all(plain), Array === KeptArray);

console.log(log.join("\n"));
