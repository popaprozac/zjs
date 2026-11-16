// One property name read off receivers of several shapes: two classes'
// methods, an array's and a string's method, the same name on functions
// and objects. What one read finds, a later read of another shape must
// not be given, and a read of the same shape must see every change a
// program makes in between.
var log = [];
function note() { var parts = []; for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i])); log.push(parts.join(" ")); }

// --- two classes' methods of one name ---
class Circle { area() { return "circle"; } }
class Square { area() { return "square"; } }
class Plain {}
var circle = new Circle(), square = new Square(), plain = new Plain();
function areaOf(shape) { return shape.area; }
function called(shape) { var f = areaOf(shape); return typeof f === "function" ? f.call(shape) : String(f); }
function round(list, times) { var seen = []; for (var t = 0; t < times; t++) for (var i = 0; i < list.length; i++) seen.push(called(list[i])); return seen.join(); }
note("one site:", round([circle, square, circle, square, plain], 2));
function both(a, b) { return a.area() + "+" + b.area(); }
note("two sites:", both(circle, square), both(square, circle), both(circle, circle), both(square, square));
Square.prototype.area = function () { return "square changed"; };
note("one changed:", round([circle, square], 2), both(circle, square));
Object.defineProperty(Circle.prototype, "area", { get: function () { return function () { return "circle through a getter"; }; }, configurable: true });
note("one an accessor:", round([circle, square], 2), both(circle, square));
Object.defineProperty(Circle.prototype, "area", { value: function () { return "circle again"; }, writable: true, configurable: true });
note("data again:", round([circle, square], 2));
circle.area = function () { return "this circle's own"; };
note("an own one:", round([circle, square, new Circle()], 2));
delete circle.area;
delete Square.prototype.area;
note("one deleted:", round([circle, square], 2));
Square.prototype.area = function () { return "square back"; };
Object.setPrototypeOf(square, Circle.prototype);
note("another prototype:", round([circle, square, new Square()], 2));
Object.setPrototypeOf(square, Square.prototype);
note("and back:", round([circle, square], 2));

// --- a shape that comes once, then another many times, then the first again ---
function label(x) { return x.label; }
class First { get other() { return 1; } }
class Second {}
First.prototype.label = "first";
Second.prototype.label = "second";
var first = new First(), second = new Second();
var run = [label(first)];
for (var n = 0; n < 40; n++) run.push(label(second));
run.push(label(first), label(first));
note("turns:", run[0], run[1], run[20], run[40], run[41], run[42]);
Second.prototype.label = "second changed";
First.prototype.label = "first changed";
var turns = [];
for (var n2 = 0; n2 < 40; n2++) turns.push(label(n2 % 2 ? first : second));
note("taking turns:", turns[0], turns[1], turns[38], turns[39], label(second), label(first));

// --- what one function found, another reads ---
function elsewhere(x) { return x.label; }
note("another site:", elsewhere(first), elsewhere(second), elsewhere(first), elsewhere(second));
Object.defineProperty(Second.prototype, "label", { get: function () { return "second through a getter"; }, configurable: true });
note("after a change:", elsewhere(second), label(second), elsewhere(first), label(first), elsewhere(second));
delete First.prototype.label;
note("after a delete:", elsewhere(first), label(first), elsewhere(second), label(second));

// --- an array's and a string's method of one name ---
var list = [1, 2, 3], text = "abc";
function find(holder, item) { return holder.indexOf(item); }
function cut(holder) { return holder.slice(1).length + holder.concat(holder).length; }
note("array and string:", find(list, 2), find(text, "c"), find(list, 3), find(text, "b"), cut(list), cut(text), cut(list), cut(text));
var arrayIndexOf = Array.prototype.indexOf;
Array.prototype.indexOf = function () { return "replaced"; };
note("the array's replaced:", find(list, 2), find(text, "c"), find(list, 2), find(text, "c"));
Array.prototype.indexOf = arrayIndexOf;
var stringIndexOf = String.prototype.indexOf;
Object.defineProperty(String.prototype, "indexOf", { get: function () { return function () { return "string getter"; }; }, configurable: true });
note("the string's an accessor:", find(list, 2), find(text, "c"), find(list, 2), find(text, "c"));
Object.defineProperty(String.prototype, "indexOf", { value: stringIndexOf, writable: true, configurable: true });
var tagged = [7, 8];
tagged.indexOf = function () { return "this array's own"; };
note("an array with its own:", find(tagged, 8), find(list, 2), find(text, "b"), find(tagged, 8), find(list, 3));

// --- one name on functions of several shapes, and on other things ---
function protoOf(x) { return x.prototype; }
function Maker() {}
var seenProtos = [];
var makers = [Object, Array, Maker, Object, Array, Maker, Circle, Object];
for (var m = 0; m < makers.length; m++) seenProtos.push(protoOf(makers[m]) === makers[m].prototype);
note("prototypes:", seenProtos.join(), protoOf(Object) === Object.prototype, protoOf(Array) === Array.prototype);
function callOf(x) { return x.call; }
var bagless = function () {}, carrying = function () {};
carrying.extra = 1;
var holderOfCall = Object.create({ call: "an object's" });
var kinds = [bagless, carrying, holderOfCall, [], "text", Object, bagless, holderOfCall, carrying];
var calls = [];
for (var k = 0; k < kinds.length; k++) { var got = callOf(kinds[k]); calls.push(got === Function.prototype.call ? "call" : String(got)); }
note("call:", calls.join());
class Left { static make() { return "left"; } }
class Right { static other() {} static make() { return "right"; } }
function made(x) { return x.make(); }
note("statics:", made(Left), made(Right), made(Left), made(Right));
Right.make = function () { return "right changed"; };
delete Left.make;
Left.make = function () { return "left again"; };
note("statics changed:", made(Left), made(Right), made(Left), made(Right));

// --- more shapes of own properties than one site keeps ---
var shapes = [{ x: 1 }, { a: 0, x: 2 }, { b: 0, a: 0, x: 3 }, { c: 0, x: 4, d: 0 }, { e: 0, f: 0, g: 0, x: 5 }, { h: 0, i: 0, j: 0, k: 0, x: 6 }, { x: 7, l: 0 }];
function xOf(o) { return o.x; }
var total = 0, order = [];
for (var pass = 0; pass < 6; pass++) for (var s = 0; s < shapes.length; s++) { total += xOf(shapes[s]); if (pass == 5) order.push(xOf(shapes[s])); }
note("seven shapes:", total, order.join());
function xAgain(o) { return o.x; }
note("at another site:", xAgain(shapes[0]), xAgain(shapes[1]), xAgain(shapes[1]), xAgain(shapes[3]), xAgain(shapes[3]), xAgain(shapes[6]), xAgain(shapes[1]), xAgain(shapes[0]), xAgain(shapes[3]));
shapes[2].x = 30;
delete shapes[4].x;
Object.defineProperty(shapes[5], "x", { get: function () { return 60; } });
var after = [];
for (var s2 = 0; s2 < shapes.length; s2++) after.push(String(xOf(shapes[s2])) + "/" + String(xOf(shapes[s2])));
note("after changes:", after.join());
function bump(o) { o.count = o.count + 1; return o.count; }
var counters = [{ count: 0 }, { pad: 0, count: 10 }, { count: 20, pad: 0 }];
var bumps = [];
for (var b = 0; b < 9; b++) bumps.push(bump(counters[b % 3]));
note("read and written:", bumps.join());

// --- many names and shapes, more than are kept ---
var objects = [];
for (var c = 0; c < 40; c++) { var holder = {}; for (var d = 0; d <= c % 8; d++) holder["pad" + d] = d; var proto = {}; for (var e = 0; e < 30; e++) proto["m" + e] = c * 100 + e; objects.push(Object.setPrototypeOf(holder, proto)); }
function sumNames(o) { return o.m0 + o.m7 + o.m13 + o.m21 + o.m29; }
var sums = 0;
for (var round2 = 0; round2 < 5; round2++) for (var c2 = 0; c2 < objects.length; c2++) sums += sumNames(objects[c2]);
note("many:", sums, sumNames(objects[0]), sumNames(objects[39]));
Object.getPrototypeOf(objects[5]).m13 = -1;
delete Object.getPrototypeOf(objects[6]).m21;
note("many changed:", sumNames(objects[5]), sumNames(objects[6]), sumNames(objects[7]), sumNames(objects[5]));

// --- many names on each of more shapes than a site keeps ---
var wide = [];
for (var w = 0; w < 7; w++) { var record = {}; for (var pad = 0; pad < w; pad++) record["lead" + pad] = 0; for (var f = 0; f < 50; f++) record["w" + ((f * 7 + w * 3) % 50)] = w * 1000 + f; wide.push(record); }
var readers = [];
for (var g = 0; g < 5; g++) { var terms = []; for (var h = 0; h < 10; h++) terms.push("o.w" + (g * 10 + h)); readers.push(new Function("o", "return " + terms.join(" + ") + ";")); }
function wideSum() { var sum = 0; for (var pass2 = 0; pass2 < 4; pass2++) for (var w2 = 0; w2 < wide.length; w2++) for (var g2 = 0; g2 < readers.length; g2++) sum += readers[g2](wide[w2]); return sum; }
note("fifty names on seven shapes:", wideSum(), readers[0](wide[6]), readers[4](wide[0]));
wide[3].w17 = -5000;
delete wide[5].w40;
note("after changes:", wideSum(), readers[1](wide[3]), readers[4](wide[5]));

// --- a hundred and fifty shapes of one field, most of them kept somewhere ---
var fielded = [];
for (var v = 0; v < 150; v++) { var one = {}; for (var lead = 0; lead <= v % 5; lead++) one["f" + v + "_" + lead] = -1; one.field = v; fielded.push(one); }
function fieldOf(o) { return o.field; }
var fields = 0;
for (var lap2 = 0; lap2 < 8; lap2++) for (var v2 = 0; v2 < fielded.length; v2++) fields += fieldOf(fielded[v2]);
note("one field on many shapes:", fields, fieldOf(fielded[149]), fieldOf(fielded[3]));

// --- far more shapes at one site than anything keeps ---
var crowd = [];
for (var u = 0; u < 300; u++) { var member = {}; member["only" + u] = u; member.tag = u; crowd.push(u % 3 ? member : Object.setPrototypeOf({}, { tag: u })); }
function tagOf(o) { return o.tag; }
var tags = 0;
for (var lap = 0; lap < 4; lap++) for (var u2 = 0; u2 < crowd.length; u2++) tags += tagOf(crowd[u2]);
note("three hundred shapes:", tags, tagOf(crowd[0]), tagOf(crowd[299]));
crowd[10].tag = -10;
Object.getPrototypeOf(crowd[9]).tag = -9;
delete crowd[11].tag;
note("after changes:", tagOf(crowd[10]), tagOf(crowd[9]), tagOf(crowd[11]), tagOf(crowd[12]), tagOf(circle), tagOf(crowd[10]));
note("the first sites still:", round([circle, square], 1), find(list, 2), find(text, "c"), xOf(shapes[1]), label(second));

console.log(log.join("\n"));
