// Getters read through the property cache: each read runs in a loop so
// the site's entry is written and then hit, and every change that must
// end a hit happens between reads.
function show(label, value) {
  console.log(label, Array.isArray(value) ? JSON.stringify(value) : String(value));
}
function reads(read, times) {
  var seen = [];
  for (var i = 0; i < times; i++) seen.push(read());
  return seen;
}

// Getters at each depth, with `this` the receiver.
class Base { constructor(v) { this.v = v; } get twice() { return this.v * 2; } }
class Middle extends Base {}
class Leaf extends Middle {}
var leaf = new Leaf(5);
var literal = { v: 3, get own() { return this.v + 1; } };
show("depths", [reads(function () { return new Base(1).twice; }, 3), reads(function () { return leaf.twice; }, 3), reads(function () { return literal.own; }, 3)]);
var deep = { get far() { return "far"; } };
for (var d = 0; d < 6; d++) deep = Object.create(deep);
show("past four", reads(function () { return deep.far; }, 3));

// A getter replaced in place, by data, and by an accessor with no getter.
var proto = { get g() { return "first"; } };
var obj = Object.create(proto);
var log = [];
function readG() { return obj.g; }
for (var r = 0; r < 3; r++) log.push(readG());
Object.defineProperty(proto, "g", { get: function () { return "second"; }, configurable: true });
for (var r2 = 0; r2 < 2; r2++) log.push(readG());
Object.defineProperty(proto, "g", { value: "data", configurable: true, writable: true });
log.push(readG());
Object.defineProperty(proto, "g", { set: function () {}, configurable: true });
log.push(String(readG()));
show("replaced", log);

// Shadowed on the object and on a prototype between (defined: the
// getter has no setter, so an assignment would not shadow it), then
// removed.
var top = { get s() { return "top"; } };
var between = Object.create(top);
var bottom = Object.create(between);
function readS() { return bottom.s; }
var shadow = [readS(), readS()];
Object.defineProperty(between, "s", { value: "between", configurable: true });
shadow.push(readS());
Object.defineProperty(bottom, "s", { value: "own", configurable: true });
shadow.push(readS());
delete bottom.s;
delete between.s;
shadow.push(readS(), readS());
delete top.s;
shadow.push(String(readS()));
show("shadowed", shadow);

// A prototype swapped.
var a = { get who() { return "a"; } };
var b = { get who() { return "b"; } };
var swapped = Object.create(a);
function readWho() { return swapped.who; }
var who = [readWho(), readWho()];
Object.setPrototypeOf(swapped, b);
who.push(readWho(), readWho());
show("swapped", who);

// A throwing getter, then reads go on.
var count = 0;
var flaky = { get x() { count++; if (count === 3) throw new RangeError("third"); return count; } };
var outcomes = [];
for (var t = 0; t < 5; t++) {
  try { outcomes.push(flaky.x); } catch (e) { outcomes.push(e.constructor.name); }
}
show("throwing", outcomes);

// One site, two classes in turn.
class Cat { get sound() { return "meow"; } }
class Dog { get sound() { return "woof"; } }
var pets = [new Cat(), new Dog(), new Cat(), new Dog(), { sound: "plain" }];
var sounds = [];
for (var p = 0; p < 10; p++) sounds.push(pets[p % 5].sound);
show("polymorphic", sounds);

// A prototype with enough properties to be a dictionary.
var big = {};
for (var n = 0; n < 80; n++) big["p" + n] = n;
Object.defineProperty(big, "computed", { get: function () { return this.p79 + 1; } });
var onBig = Object.create(big);
show("dictionary", reads(function () { return onBig.computed; }, 3));

// Builtin getters: Map's size, a typed array's length and byteLength, a
// DataView's, and the global object.
var map = new Map([[1, 1]]);
var sizes = reads(function () { return map.size; }, 2);
map.set(2, 2);
sizes.push(map.size);
var ta = new Uint16Array(8);
var lengths = reads(function () { return ta.length + ":" + ta.byteLength; }, 3);
ta.buffer.transfer();
lengths.push(ta.length + ":" + ta.byteLength);
var other = new Uint16Array(3);
Object.defineProperty(other, "length", { value: 99 });
lengths.push(reads(function () { return other.length; }, 2).join("/"));
var dv = new DataView(new ArrayBuffer(6), 2);
show("builtins", [JSON.stringify(sizes), JSON.stringify(lengths), reads(function () { return dv.byteLength; }, 3).join()]);
Object.defineProperty(globalThis, "globalGetter", { get: function () { return "global"; }, configurable: true });
show("global", reads(function () { return globalThis.globalGetter; }, 3));

// A typed array answers numeric names itself, even when a prototype has
// one.
Uint8Array.prototype.NaN = "from prototype";
Object.defineProperty(Uint8Array.prototype, "Infinity", { get: function () { return "getter"; }, configurable: true });
var bytes = new Uint8Array(2);
show("numeric names", [reads(function () { return String(bytes.NaN); }, 3).join(), reads(function () { return String(bytes.Infinity); }, 3).join(), Object.create(bytes).foo]);
delete Uint8Array.prototype.NaN;
delete Uint8Array.prototype.Infinity;
