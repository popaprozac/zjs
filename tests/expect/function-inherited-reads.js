// A read on a function of a name it inherits from Function.prototype,
// or of one it computes (`prototype`, `length`, `name`), goes through
// the site's cache once the site has seen it. Each case reads through
// one site twice or more, changes something a program can change, and
// reads through the same site again.
var log = [];
function note() { var parts = []; for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i])); log.push(parts.join(" ")); }
function shared(x) { return x.shared; }
function twice(x) { return String(shared(x)) + " " + String(shared(x)); }

// --- the kinds of function ---
class Shape { static make() {} }
function plain() {}
var closure = (function (kept) { return function () { return kept; }; })(1);
var arrow = () => 1;
async function later() {}
function* steps() {}
var bound = plain.bind(null);
var method = { m() {} }.m;
var kinds = [plain, closure, arrow, later, steps, bound, method, Shape, Object, Math.max];
function callOf(x) { return x.call; }
var same = 0;
for (var i = 0; i < kinds.length; i++) { if (callOf(kinds[i]) === Function.prototype.call && callOf(kinds[i]) === Function.prototype.call) same++; }
note("call on every kind:", same, kinds.length);
function applied(f) { return f.apply(null, [2, 3]) + f.call(null, 4, 5) + f.bind(null, 6)(7); }
function sum(a, b) { return a + b; }
note("called through them:", applied(sum), applied(sum), applied(Math.max), applied(function (a, b) { return a * b; }));

// --- a name on Function.prototype, and everything that can hide or change it ---
note("absent:", twice(plain), twice(Shape));
Function.prototype.early = "before it";
Function.prototype.shared = "inherited";
note("added to Function.prototype:", twice(plain), twice(closure), twice(arrow), twice(Shape), twice(Object));
Function.prototype.shared = "changed";
note("changed there:", twice(plain), twice(Shape));
plain.shared = "own";
note("own hides it:", twice(plain), twice(closure));
delete plain.shared;
note("own deleted:", twice(plain));
var reads = 0;
Object.defineProperty(Function.prototype, "shared", { get: function () { reads++; return this === plain ? "getter on plain" : "getter elsewhere"; }, configurable: true });
note("an accessor there:", twice(plain), twice(closure), reads);
Object.defineProperty(Function.prototype, "shared", { value: "data again", writable: true, configurable: true });
note("data again:", twice(plain), twice(closure));

// --- another prototype ---
function moved() {}
note("before:", twice(moved));
Object.setPrototypeOf(moved, { shared: "another prototype's" });
note("another prototype:", twice(moved), twice(plain));
Object.setPrototypeOf(moved, Function.prototype);
note("back:", twice(moved));
Object.setPrototypeOf(moved, null);
note("none:", twice(moved), typeof moved.call);
class Base { static make() {} }
class Derived extends Base {}
note("through a parent class:", twice(Derived), twice(Base));
Base.shared = "base's";
note("the parent's own:", twice(Derived), twice(Base));

// --- a function's own properties around it ---
function carrier() {}
carrier.a = 1;
note("with other properties:", twice(carrier));
carrier.b = 2;
note("with more:", twice(carrier));
delete carrier.a;
note("after losing one:", twice(carrier), Object.keys(carrier).join());
function crowded() {}
for (var k = 0; k < 200; k++) crowded["p" + k] = k;
note("with 200:", twice(crowded));
crowded.shared = "crowded's own";
note("and its own:", twice(crowded));

// --- one site, many receivers ---
var object = { shared: "object's" };
var array = [1];
array.shared = "array's";
var owner = function () {};
owner.shared = "owner's";
var receivers = [plain, object, closure, array, "text", owner, 7, moved, plain, Derived, owner, arrow];
var seen = [];
for (var r = 0; r < receivers.length; r++) seen.push(String(shared(receivers[r])));
note("mixed:", seen.join(" | "));

// --- a site that has seen only functions, then other cells ---
function callAt(x) { return x.call; }
note("functions, then other cells:", callAt(plain) === Function.prototype.call, callAt(closure) === Function.prototype.call, callAt([5]), callAt("text"), callAt(plain) === Function.prototype.call, callAt({ a: 1 }), callAt(Symbol("s")), callAt(/x/), callAt([{ call: "inner" }]), callAt(arrow) === Function.prototype.call);

// --- names Object.prototype holds ---
function deep(x) { return x.deep; }
note("on neither:", deep(plain), deep(plain));
Object.prototype.deep = "Object.prototype's";
note("on Object.prototype:", deep(plain), deep(plain), deep(Shape));
Function.prototype.deep = "Function.prototype's";
note("hidden by Function.prototype:", deep(plain), deep(plain), deep(Shape));
delete Function.prototype.deep;
note("shown again:", deep(plain), deep(plain));
delete Object.prototype.deep;
note("gone:", deep(plain), deep(plain));

// --- prototype ---
function protoOf(x) { return x.prototype; }
function Maker() {}
var first = protoOf(Maker);
note("made on first use:", typeof first, protoOf(Maker) === first, first.constructor === Maker, first === Maker.prototype);
function Fresh() {}
note("another function at the same site:", protoOf(Fresh) === Fresh.prototype, protoOf(Fresh) === protoOf(Fresh), protoOf(Fresh) === first, protoOf(Fresh).constructor === Fresh);
var built = [new bound(), Reflect.construct(function () {}, [], bound), Reflect.construct(Maker, [], bound)];
note("functions without one:", protoOf(arrow), protoOf(later), protoOf(method), protoOf(bound), protoOf(Math.max), protoOf(arrow));
note("a generator function's:", typeof protoOf(steps), protoOf(steps) === protoOf(steps), Object.getPrototypeOf(steps()) === protoOf(steps));
note("a builtin's and a class's:", protoOf(Object) === Object.prototype, protoOf(Array) === Array.prototype, protoOf(Shape) === Shape.prototype, protoOf(Object) === Object.getPrototypeOf({}));
Maker.prototype = { replaced: true };
note("assigned:", protoOf(Maker).replaced, protoOf(Maker) === first, new Maker().replaced);
Object.defineProperty(Fresh, "prototype", { value: first });
note("defined:", protoOf(Fresh) === first, protoOf(Fresh) === first);
var order = [Maker, arrow, Fresh, Object, bound, steps, Maker];
var kindsSeen = [];
for (var o = 0; o < order.length; o++) kindsSeen.push(typeof protoOf(order[o]));
note("mixed:", kindsSeen.join());

// --- name ---
function nameOf(x) { return x.name; }
var inferred = function () {};
note("names:", nameOf(plain), nameOf(inferred), nameOf(arrow), nameOf(Shape), nameOf(bound), nameOf(Object), nameOf(Math.max), nameOf(method));
note("no name:", JSON.stringify(nameOf((function () { return function () {}; })())), JSON.stringify(nameOf((() => () => 1)())));
Object.defineProperty(plain, "name", { value: "renamed" });
note("defined:", nameOf(plain), nameOf(plain), nameOf(inferred));
delete plain.name;
note("deleted:", JSON.stringify(nameOf(plain)), JSON.stringify(nameOf(plain)), nameOf(inferred));
delete inferred.name;
note("deleted on another:", JSON.stringify(nameOf(inferred)), nameOf(Shape), nameOf({ name: "an object's" }), nameOf(Shape));

// --- length ---
function lengthOf(x) { return x.length; }
function two(a, b) {}
note("lengths:", lengthOf(two), lengthOf(two), lengthOf(arrow), lengthOf(two.bind(null, 1)), lengthOf(Math.max), lengthOf(class { constructor(a, b, c) {} }), lengthOf(function (a, b = 1, c) {}));
note("beside arrays and strings:", lengthOf([1, 2, 3]), lengthOf(two), lengthOf("abcd"), lengthOf({ length: 9 }), lengthOf(two), lengthOf([]));
Object.defineProperty(two, "length", { value: 7 });
note("defined:", lengthOf(two), lengthOf(two));
delete two.length;
note("deleted:", lengthOf(two), lengthOf(two), lengthOf(sum));

// --- read off an element ---
var entries = [plain, { name: "an object" }, arrow, Shape, sum];
var elementNames = [];
for (var e = 0; e < entries.length; e++) elementNames.push(JSON.stringify(entries[e].name));
for (var e2 = 0; e2 < entries.length; e2++) elementNames.push(typeof entries[e2].call);
note("elements:", elementNames.join());

// --- what throws still throws ---
function failing(x) { try { return x.call; } catch (error) { return error.constructor.name; } }
Object.defineProperty(owner, "call", { get: function () { throw new RangeError("no"); } });
note("errors:", failing(null), failing(undefined), failing(owner), typeof failing(plain), failing(owner));
var holes = [undefined, plain];
function elementCall(list, at) { try { return typeof list[at].call; } catch (error) { return error.constructor.name; } }
note("element errors:", elementCall(holes, 0), elementCall(holes, 1), elementCall(holes, 0));

// --- Function.prototype with many properties ---
for (var q = 0; q < 200; q++) Function.prototype["q" + q] = q;
note("a crowded Function.prototype:", twice(plain), twice(closure), typeof callOf(plain), callOf(plain) === Function.prototype.call, plain.q199);
Function.prototype.shared = "changed in the crowd";
note("changed there:", twice(plain), twice(arrow));
delete Function.prototype.early;
for (var q2 = 0; q2 < 3000; q2++) { Function.prototype["r" + q2] = q2; delete Function.prototype["r" + q2]; }
// The site last read `arrow`: the same receiver again, so nothing between re-records it.
note("after it lost an earlier one:", twice(arrow), twice(plain), plain.early, plain.q7);

console.log(log.join("\n"));
