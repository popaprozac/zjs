// A read of a function's own property goes through the site's cache
// once the site has seen it. Each case reads through one site twice or
// more, changes the function, and reads through the same site again:
// the read must see what a program can do to the property between.
var log = [];
function note() { log.push(Array.prototype.join.call(arguments, " ")); }
function show(value) { return typeof value === "function" ? "fn:" + value.name : String(value); }
function make(x) { return x.make; }
function twice(x) { return show(make(x)) + " " + show(make(x)); }

// --- the kinds of function ---
class Shape { static make() { return "shape"; } }
function plain() {}
plain.make = "plain";
var closure = (function (kept) { return function () { return kept; }; })(1);
closure.make = "closure";
var arrow = () => 1;
arrow.make = "arrow";
async function later() {}
later.make = "async";
function* steps() {}
steps.make = "generator";
var bound = plain.bind(null);
bound.make = "bound";
note("kinds:", twice(Shape), twice(plain), twice(closure), twice(arrow), twice(later), twice(steps), twice(bound));
function resolveOf(x) { return x.resolve; }
note("builtin:", resolveOf(Promise) === Promise.resolve, resolveOf(Promise) === resolveOf(Promise), resolveOf(Promise).name);

// --- the value changes in place ---
function Counter() {}
Counter.make = 1;
note("before:", twice(Counter));
Counter.make = 2;
note("assigned:", twice(Counter));
Object.defineProperty(Counter, "make", { value: 3 });
note("defined:", twice(Counter));
function bump(x) { x.count = x.count + 1; return x.count; }
Counter.count = 0;
note("read and written through one name:", bump(Counter), bump(Counter), bump(Counter), bump({ count: 10 }), bump(Counter));

// --- the property changes kind ---
var reads = 0;
Object.defineProperty(Counter, "make", { get: function () { reads++; return this === Counter ? "getter on Counter" : "getter elsewhere"; }, configurable: true });
note("accessor:", twice(Counter), reads);
Object.defineProperty(Counter, "make", { value: "data again", writable: false, configurable: true });
note("data again:", twice(Counter));
Counter.make = "ignored";
note("read-only:", twice(Counter));
Object.freeze(Counter);
note("frozen:", twice(Counter), Object.isFrozen(Counter));

// --- deleted, and what shows through ---
class Base { static make() { return "base"; } }
class Derived extends Base {}
note("inherited static:", twice(Derived), make(Derived) === Base.make);
Derived.make = "own";
note("shadowed:", twice(Derived));
delete Derived.make;
note("deleted:", twice(Derived), make(Derived) === Base.make);
Derived.make = "own again";
note("added again:", twice(Derived));
function loose() {}
note("absent:", twice(loose));
Function.prototype.make = "from Function.prototype";
note("from the prototype:", twice(loose));
loose.make = "own";
note("then own:", twice(loose));
delete loose.make;
note("then deleted:", twice(loose));
delete Function.prototype.make;
note("then gone:", twice(loose));

// --- names a function has without holding them ---
function nameOf(x) { return x.name; }
function named() {}
note("name:", nameOf(named), nameOf(named));
Object.defineProperty(named, "name", { value: "renamed" });
note("defined name:", nameOf(named), nameOf(named));
delete named.name;
note("deleted name:", JSON.stringify(nameOf(named)), JSON.stringify(nameOf(named)), named.hasOwnProperty("name"));
function protoOf(x) { return x.prototype; }
function Maker() {}
var first = protoOf(Maker);
note("prototype:", first === Maker.prototype, protoOf(Maker) === first);
Maker.prototype = { replaced: true };
note("replaced prototype:", protoOf(Maker).replaced, protoOf(Maker) === Maker.prototype, protoOf(Maker) === first);

// --- one site, many receivers ---
class A { static make() { return "A"; } }
class B { static make() { return "B"; } }
class C { static other() {} static make() { return "C"; } }
var object = { make: "object" };
var array = [1, 2];
array.make = "array";
var receivers = [A, B, C, object, array, "text", 7, A, object, C, B, array, plain];
var seen = [];
for (var i = 0; i < receivers.length; i++) { var got = make(receivers[i]); seen.push(typeof got === "function" ? got() : String(got)); }
note("mixed:", seen.join());

// --- a cell that is no function, holding an object shaped like a function's properties ---
var lookalike = [{ make: "inner" }];
var symbol = Symbol("make");
note("not a function:", show(make(plain)), show(make(lookalike)), show(make(plain)), show(make(symbol)), show(make(plain)), show(make(/make/)), show(make(lookalike)));

// --- a function with many properties, and one that lost a property ---
function crowded() {}
for (var k = 0; k < 200; k++) crowded["p" + k] = k;
crowded.make = "crowded";
note("many properties:", twice(crowded));
crowded.make = "crowded changed";
note("changed there:", twice(crowded));
function holed() {}
holed.a = 1; holed.make = "holed"; holed.b = 2;
note("before the delete:", twice(holed));
delete holed.a;
note("after it:", twice(holed), Object.keys(holed).join());
holed.make = "holed changed";
note("changed after it:", twice(holed));

// --- other prototypes do not reach an own property ---
function moved() {}
moved.make = "moved";
note("own:", twice(moved));
Object.setPrototypeOf(moved, { make: "prototype's", extra: "inherited" });
note("another prototype:", twice(moved), moved.extra);
delete moved.make;
note("its own gone:", twice(moved));

console.log(log.join("\n"));
