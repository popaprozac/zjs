// A name found past an object's first prototype, or found nowhere, is
// remembered with the classes of the prototypes passed. Each case reads
// through one site twice or more, changes something along the chain,
// and reads through the same site again.
var log = [];
function note() { var parts = []; for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i])); log.push(parts.join(" ")); }
function tag(o) { return o.tag; }
function twice(o) { return String(tag(o)) + " " + String(tag(o)); }
function missing(o) { return o.missing; }
function both(o) { return String(missing(o)) + " " + String(missing(o)); }

// --- found two, three, four, and five prototypes away ---
class Base {}
class Mid extends Base {}
class Leaf extends Mid {}
class Twig extends Leaf {}
class Bud extends Twig {}
Base.prototype.tag = "base";
var mid = new Mid(), leaf = new Leaf(), twig = new Twig(), bud = new Bud(), base = new Base();
note("depths:", twice(base), twice(mid), twice(leaf), twice(twig), twice(bud));
Base.prototype.tag = "base changed";
note("changed at the holder:", twice(mid), twice(leaf), twice(bud));
Mid.prototype.tag = "mid";
note("added nearer:", twice(mid), twice(leaf), twice(twig), twice(base));
delete Mid.prototype.tag;
note("removed again:", twice(mid), twice(leaf), twice(twig));
leaf.tag = "this leaf's own";
note("an own one:", twice(leaf), twice(new Leaf()), twice(twig));
delete leaf.tag;
note("own removed:", twice(leaf));
var reads = 0;
Object.defineProperty(Base.prototype, "tag", { get: function () { reads++; return this === mid ? "getter on mid" : "getter elsewhere"; }, configurable: true });
note("an accessor at the holder:", twice(mid), twice(leaf), reads);
Object.defineProperty(Base.prototype, "tag", { value: "data again", writable: true, configurable: true });
note("data again:", twice(mid), twice(leaf), twice(bud));
Object.defineProperty(Mid.prototype, "tag", { get: function () { return "getter on the way"; }, configurable: true });
note("an accessor on the way:", twice(mid), twice(leaf), twice(base));
delete Mid.prototype.tag;
note("and gone:", twice(mid), twice(leaf));

// --- a prototype changed along the chain ---
var side = { tag: "side" };
Object.setPrototypeOf(Mid.prototype, side);
note("the chain cut over:", twice(mid), twice(leaf), twice(base));
Object.setPrototypeOf(Mid.prototype, Base.prototype);
note("and back:", twice(mid), twice(leaf));
Object.setPrototypeOf(leaf, { tag: "leaf's new prototype" });
note("the object's own prototype:", twice(leaf), twice(new Leaf()), twice(mid));
Object.setPrototypeOf(leaf, Leaf.prototype);
var between = Object.create(Base.prototype);
Object.setPrototypeOf(Mid.prototype, between);
note("one more on the way:", twice(mid), twice(leaf));
between.tag = "between";
note("and it has the name:", twice(mid), twice(leaf), twice(base));
Object.setPrototypeOf(Mid.prototype, Base.prototype);
note("restored:", twice(mid), twice(leaf));
for (var k = 0; k < 200; k++) Mid.prototype["m" + k] = k;
note("a crowded prototype on the way:", twice(mid), twice(leaf), mid.m199);
Base.prototype.tag = "base under a crowd";
note("changed under it:", twice(mid), twice(leaf));
Mid.prototype.tag = "in the crowd";
note("the crowded one gets the name:", twice(mid), twice(leaf), twice(base));
delete Mid.prototype.tag;
note("and loses it:", twice(mid), twice(leaf), both(mid), both(leaf));
Mid.prototype.missing = "in the crowd too";
note("and gets another:", both(mid), both(leaf), both(base));
delete Mid.prototype.missing;

// --- found nowhere ---
var plain = { a: 1 }, bare = Object.create(null), other = new Base();
note("nowhere:", both(plain), both(bare), both(other), both(new Leaf()), both(bud));
plain.missing = "now its own";
note("added to the object:", both(plain), both({ a: 2 }));
delete plain.missing;
note("removed:", both(plain));
Object.prototype.missing = "on Object.prototype";
note("added at the end of the chain:", both(plain), both(other), both(new Leaf()), both(bare));
delete Object.prototype.missing;
note("removed there:", both(plain), both(other));
Base.prototype.missing = "on Base.prototype";
note("added in the middle:", both(other), both(new Leaf()), both(plain));
delete Base.prototype.missing;
Object.defineProperty(Object.prototype, "missing", { get: function () { return "a getter at the end"; }, configurable: true });
note("an accessor at the end:", both(plain), both(other));
delete Object.prototype.missing;
note("and gone:", both(plain), both(other), both(bare));
Object.setPrototypeOf(bare, { missing: "bare's new prototype" });
note("an object that had no prototype:", both(bare), both(Object.create(null)));
Object.setPrototypeOf(plain, null);
note("an object that loses its prototype:", both(plain), typeof plain.toString);
var ended = Object.create(null);
ended.pad = 1;
var onTop = Object.create(ended);
note("a chain that ends:", both(onTop), both(onTop));
Object.setPrototypeOf(ended, { missing: "added past the end" });
note("and then goes on:", both(onTop), both(onTop), both(Object.create(Object.create(null))));
class One {}
class Two {}
var ones = [new One(), new Two(), new One(), new Two(), new One(), new Two()];
var fieldless = [];
for (var f = 0; f < ones.length; f++) fieldless.push(String(missing(ones[f])));
One.prototype.missing = "one";
for (var f2 = 0; f2 < ones.length; f2++) fieldless.push(String(missing(ones[f2])));
delete One.prototype.missing;
Two.prototype.missing = "two";
for (var f3 = 0; f3 < ones.length; f3++) fieldless.push(String(missing(ones[f3])));
delete Two.prototype.missing;
note("two classes without fields:", fieldless.join());
var holdsUndefined = Object.create(Object.create({ missing: undefined, tag: undefined }));
note("found holding undefined:", both(holdsUndefined), twice(holdsUndefined), "missing" in holdsUndefined);

// --- options some objects have and some do not ---
function limitOf(options) { return options.limit === undefined ? "default" : options.limit; }
var sets = [{ limit: 1 }, { size: 2 }, { size: 3, limit: 4 }, {}, { limit: 5, size: 6 }, { other: 7 }];
var limits = [];
for (var lap = 0; lap < 3; lap++) for (var s = 0; s < sets.length; s++) limits.push(limitOf(sets[s]));
note("options:", limits.join());
sets[1].limit = 20;
delete sets[0].limit;
note("options changed:", limitOf(sets[0]), limitOf(sets[1]), limitOf(sets[3]), limitOf(sets[0]), limitOf(sets[1]));

// --- written after it was read as absent ---
function count(o) { if (o.count === undefined) o.count = 0; o.count = o.count + 1; return o.count; }
var counted = {}, counted2 = { pad: 1 };
note("read, then written:", count(counted), count(counted), count(counted2), count(counted), count(counted2), count({}));

// --- receivers that answer for themselves ---
function arrayOf(o) { return o.Array; }
function parseOf(o) { return o.parseInt; }
note("the global object:", arrayOf({}), arrayOf({}), arrayOf(globalThis) === Array, arrayOf(globalThis) === Array, arrayOf({}), parseOf(Object.create(null)), parseOf(globalThis) === parseInt, parseOf({}), parseOf(globalThis) === parseInt);
function lengthOf(o) { return o.length; }
var numberBox = new Number(5), stringBox = new String("four"), emptyOne = {};
note("wrappers:", lengthOf(numberBox), lengthOf(numberBox), lengthOf(stringBox), lengthOf(stringBox), lengthOf(emptyOne), lengthOf(new String("sixsix")), lengthOf(numberBox));
function owns(o) { return o.hasOwnProperty; }
var held = Object.create([1, 2]), fromFunction = Object.create(function () {});
note("other kinds on the way:", owns(held) === Object.prototype.hasOwnProperty, owns(fromFunction) === Object.prototype.hasOwnProperty, owns(mid) === Object.prototype.hasOwnProperty, owns(held) === Object.prototype.hasOwnProperty, missing(held), missing(fromFunction), missing(held));
note("arrays, functions, strings:", missing([]), missing(function () {}), missing("text"), missing([]), tag([]), tag(7));

// --- more shapes than a site keeps ---
var shapes = [];
for (var n = 0; n < 40; n++) { var one = {}; for (var pad = 0; pad < n % 7; pad++) one["p" + n + "_" + pad] = pad; shapes.push(n % 2 ? one : Object.setPrototypeOf(one, n % 4 ? new Mid() : new Twig())); }
var seen = [];
for (var lap2 = 0; lap2 < 3; lap2++) for (var n2 = 0; n2 < shapes.length; n2++) { if (lap2 == 2 && n2 < 8) seen.push(String(tag(shapes[n2])) + "/" + String(missing(shapes[n2]))); else { tag(shapes[n2]); missing(shapes[n2]); } }
note("many shapes:", seen.join(" "));
Base.prototype.tag = "base at the end";
Object.prototype.missing = 0;
var after = [];
for (var n3 = 0; n3 < 8; n3++) after.push(String(tag(shapes[n3])) + "/" + String(missing(shapes[n3])));
note("after changes:", after.join(" "));
delete Object.prototype.missing;

// --- another site, and a method call ---
class Animal { speak() { return "animal " + this.name; } }
class Dog extends Animal { constructor(name) { super(); this.name = name; } }
class Puppy extends Dog {}
function speak(a) { return a.speak(); }
var rex = new Dog("rex"), pip = new Puppy("pip");
note("calls:", speak(rex), speak(pip), speak(rex), speak(pip), rex.hasOwnProperty("name"), pip.hasOwnProperty("speak"), rex.hasOwnProperty("name"));
Dog.prototype.speak = function () { return "dog " + this.name; };
note("overridden:", speak(rex), speak(pip), speak(new Animal()));
delete Dog.prototype.speak;
note("override removed:", speak(rex), speak(pip));

console.log(log.join("\n"));
