// A store that adds a property is remembered with the transition it
// took and the prototypes it passed, two to four of them for an
// instance of a class (one, two, or three levels deep), or for an
// object whose chain ends in one without a prototype. Each kind of
// receiver has a site of its own, which adds to fresh objects, and
// between rounds something along the chain changes.
var log = [];
function note() { var parts = []; for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i])); log.push(parts.join(" ")); }
var own = Object.prototype.hasOwnProperty;
function site(strict) { return Function("o", "v", (strict ? '"use strict"; ' : "") + "o.name = v; return o;"); }
var sloppy = [], strict = [];
for (var s = 0; s < 7; s++) { sloppy.push(site(false)); strict.push(site(true)); }
function adds(make, at) { var out = []; for (var i = 0; i < 3; i++) { var o = sloppy[at](make(), i); out.push(o.name + (own.call(o, "name") ? "" : "(inherited)")); } return out.join(","); }
function strictAdds(make, at) { try { return strict[at](make(), "s").name; } catch (e) { return e.constructor.name; } }

class Base {}
class Leaf extends Base {}
class Twig extends Leaf {}
class Bud extends Twig {}
var end3 = Object.create(null), end4 = Object.create(null);
var top3 = Object.create(Object.create(end3)), top4 = Object.create(Object.create(Object.create(end4)));
var all = [function () { return {}; }, function () { return new Base(); }, function () { return new Leaf(); }, function () { return new Twig(); }, function () { return new Bud(); }, function () { return Object.create(top3); }, function () { return Object.create(top4); }];
function each(f) { return all.map(f).join(" / "); }
function both() { return each(adds) + " " + each(strictAdds); }

note("warm:", both());
note("again:", both());

// A setter on each prototype in turn takes the store over.
var calls = [];
[["Leaf", Leaf.prototype], ["Base", Base.prototype], ["Object", Object.prototype]].forEach(function (pair) {
  var at = pair[0], holder = pair[1];
  Object.defineProperty(holder, "name", { set: function (v) { calls.push(at + ":" + v); }, get: function () { return "via setter " + at; }, configurable: true });
  note("a setter on " + at + ".prototype:", both(), calls.join(" "));
  calls.length = 0;
  delete holder.name;
  note("and removed:", both());
});

// A read-only property on the way refuses the add, silently or with a
// TypeError in strict code.
[["Twig", Twig.prototype], ["Base", Base.prototype], ["Object", Object.prototype]].forEach(function (pair) {
  var at = pair[0], holder = pair[1];
  Object.defineProperty(holder, "name", { value: "fixed " + at, writable: false, configurable: true });
  note("read-only on " + at + ".prototype:", both());
  delete holder.name;
  note("and removed:", both());
});

// Data on the way is shadowed by the add, until it is made read-only
// where it stands.
[["Base", Base.prototype], ["Object", Object.prototype]].forEach(function (pair) {
  var at = pair[0], holder = pair[1];
  holder.name = "data on " + at;
  note("data on " + at + ".prototype:", both());
  Object.defineProperty(holder, "name", { writable: false });
  note("made read-only:", both());
  delete holder.name;
  note("and removed:", both());
});

// The chain changed: longer, shorter, through another object.
var side = Object.create(Object.prototype, { name: { set: function (v) { calls.push("side:" + v); }, configurable: true } });
Object.setPrototypeOf(Base.prototype, side);
note("longer, with a setter:", both(), calls.join(" "));
calls.length = 0;
Object.setPrototypeOf(Base.prototype, Object.create(Object.prototype));
note("longer, without:", both());
Object.setPrototypeOf(Base.prototype, null);
note("shorter:", both());
Object.setPrototypeOf(Base.prototype, Object.prototype);
note("restored:", both());
var lookalike = Object.create(Base.prototype, { name: { set: function (v) { calls.push("between:" + v); }, configurable: true } });
Object.setPrototypeOf(Twig.prototype, lookalike);
note("a prototype swapped:", both(), calls.join(" "));
calls.length = 0;
Object.setPrototypeOf(Twig.prototype, Leaf.prototype);
note("swapped back:", both());
// A second prototype swapped for an object of the same shape that has
// the name further up.
var upper = Object.create(Object.prototype, { name: { set: function (v) { calls.push("upper:" + v); }, configurable: true } });
var twin = Object.create(upper);
Object.setPrototypeOf(Leaf.prototype, twin);
note("a twin with a setter behind it:", both(), calls.join(" "));
calls.length = 0;
Object.setPrototypeOf(Leaf.prototype, Base.prototype);
note("and back:", both());

// Receivers that refuse new properties, and receivers of another shape.
note("non-extensible:", each(function (make, at) { var o = Object.preventExtensions(make()); sloppy[at](o, 1); return own.call(o, "name") + ":" + strictAdds(function () { return Object.preventExtensions(make()); }, at); }));
note("another shape:", each(function (make, at) { var o = make(); o.first = 0; sloppy[at](o, 1); return Object.keys(o).join() + "=" + o.name; }));
note("again:", both());

// The last prototype of a chain given one, with a setter for the name.
var catcher = Object.create(null, { name: { set: function (v) { calls.push("end:" + v); }, configurable: true } });
Object.setPrototypeOf(end3, catcher);
Object.setPrototypeOf(end4, catcher);
note("the end given a prototype:", both(), calls.join(" "));
calls.length = 0;
Object.setPrototypeOf(end3, null);
Object.setPrototypeOf(end4, null);
note("and taken away:", both());

// A prototype gains other properties, or turns into a dictionary.
Base.prototype.other = 1;
Leaf.prototype.another = 2;
note("prototypes grown:", both());
for (var k = 0; k < 80; k++) Base.prototype["p" + k] = k;
delete Base.prototype.p3;
note("a dictionary prototype:", both());
Object.defineProperty(Base.prototype, "name", { set: function (v) { calls.push("dict:" + v); }, configurable: true });
note("a setter on it:", both(), calls.join(" "));
calls.length = 0;
delete Base.prototype.name;
note("removed:", both());

note("frozen prototypes:", (Object.freeze(Leaf.prototype), both()));

// What the sites remembered survives collections.
if (typeof gc === "function") gc();
note("after a collection:", both());

// A prototype holding a writable data property of the name: the store
// shadows it, and the site remembers that too, until the property turns
// read-only or an accessor, or goes.
function shadowRound(Make, holder, label) {
  var outcome = [];
  for (var i = 0; i < 3; i++) {
    var a = new Make(); shadowSloppy(a, "s" + i);
    var b = new Make(); var threw = "";
    try { shadowStrict(b, "t" + i); } catch (e) { threw = "!" + e.constructor.name; }
    outcome.push(own.call(a, "name") + ":" + a.name + "/" + own.call(b, "name") + ":" + b.name + threw);
  }
  note(label, outcome.join(" "), "holder:", holder.name);
}
var shadowSloppy = site(false), shadowStrict = site(true);
function Shadow() {}
Shadow.prototype.name = "proto";
shadowRound(Shadow, Shadow.prototype, "shadowed:");
Shadow.prototype.name = "changed";
shadowRound(Shadow, Shadow.prototype, "its value changed:");
Object.defineProperty(Shadow.prototype, "name", { writable: false });
shadowRound(Shadow, Shadow.prototype, "read-only:");
Object.defineProperty(Shadow.prototype, "name", { writable: true });
shadowRound(Shadow, Shadow.prototype, "writable again:");
var shadowCalls = [];
Object.defineProperty(Shadow.prototype, "name", { get: function () { return "got"; }, set: function (v) { shadowCalls.push(v); }, configurable: true });
shadowRound(Shadow, Shadow.prototype, "an accessor:");
note("its setter saw:", shadowCalls.join(" "));
delete Shadow.prototype.name;
shadowRound(Shadow, Shadow.prototype, "removed:");
Shadow.prototype.name = "back";
shadowRound(Shadow, Shadow.prototype, "back:");
Object.freeze(Shadow.prototype);
shadowRound(Shadow, Shadow.prototype, "frozen:");
// Two prototypes up, the same.
var deepHolder = { name: "deep" };
function Deep() {}
Deep.prototype = Object.create(deepHolder);
shadowRound(Deep, deepHolder, "shadowed two up:");
Object.defineProperty(deepHolder, "name", { writable: false });
shadowRound(Deep, deepHolder, "read-only two up:");
// A setter that defines the property on the receiver itself: the store
// ran code, so every store at the site must run it again.
var definer = [];
function Definer() {}
Object.defineProperty(Definer.prototype, "name", { set: function (v) { definer.push(v); Object.defineProperty(this, "name", { value: v, writable: true, enumerable: true, configurable: true }); }, configurable: true });
for (var i = 0; i < 3; i++) { shadowSloppy(new Definer(), "d" + i); shadowStrict(new Definer(), "e" + i); }
note("a setter that defines it:", definer.join(" "));
console.log(log.join("\n"));
