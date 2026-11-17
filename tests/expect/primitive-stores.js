// A write to a property of a primitive is [[Set]] on its wrapper with the
// primitive as the receiver: a setter on the prototype chain runs against
// the primitive, and nothing else takes the write, since no property can
// be made on the receiver. Strict code throws a TypeError for the refused
// write and sloppy code ignores it.
function t(label, f) {
  try { console.log(label, "->", String(f())); }
  catch (e) { console.log(label, "threw", e.name); }
}
var sym = Symbol("s");
var setterLog = [];
var keyLog = [];
Object.defineProperty(Number.prototype, "viaSetter", { set: function (v) { "use strict"; setterLog.push(typeof this + ":" + v); }, configurable: true });
Object.defineProperty(String.prototype, "viaSetter", { set: function (v) { "use strict"; setterLog.push(typeof this + ":" + v); }, configurable: true });
Object.defineProperty(Object.prototype, "viaObjectSetter", { set: function (v) { setterLog.push("sloppy setter " + typeof this + ":" + v); }, configurable: true });
Object.defineProperty(String.prototype, "0", { set: function (v) { setterLog.push("index 0 setter"); }, configurable: true });
Object.defineProperty(String.prototype, "7", { set: function (v) { "use strict"; setterLog.push("index 7 setter " + typeof this); }, configurable: true });
Object.defineProperty(Number.prototype, "getOnly", { get: function () { return 1; }, configurable: true });
Object.defineProperty(Number.prototype, "readOnly", { value: 1, writable: false, configurable: true });
Number.prototype.inherited = 1;
var setterKey = { toString: function () { keyLog.push("setterKey"); return "viaSetter"; } };
var plainKey = { toString: function () { keyLog.push("plainKey"); return "kk"; } };
var badKey = { toString: function () { throw new RangeError("key"); } };

(function () {
  "use strict";
  var n = 0, s = "ab", b = true, y = sym;
  // Every form of assignment, on a number.
  t("strict n.k = 1", function () { n.k = 1; return "no throw"; });
  t("strict n.k++", function () { n.k++; return "no throw"; });
  t("strict ++n.k", function () { ++n.k; return "no throw"; });
  t("strict n.k += 1", function () { n.k += 1; return "no throw"; });
  t("strict n.k ||= 5", function () { n.k ||= 5; return "no throw"; });
  t("strict n.k ??= 5", function () { n.k ??= 5; return "no throw"; });
  t("strict n.k &&= 5, not assigned", function () { n.k &&= 5; return "no throw"; });
  t("strict n['k'] = 1", function () { n["k"] = 1; return "no throw"; });
  t("strict n[0] = 1", function () { n[0] = 1; return "no throw"; });
  t("strict n[sym] = 1", function () { n[sym] = 1; return "no throw"; });
  t("strict [n.k] = [1]", function () { [n.k] = [1]; return "no throw"; });
  t("strict ({ a: n.k } = { a: 1 })", function () { ({ a: n.k } = { a: 1 }); return "no throw"; });
  t("strict for (n.k of [1])", function () { for (n.k of [1]) {} return "no throw"; });
  t("strict for (n.k in { a: 1 })", function () { for (n.k in { a: 1 }) {} return "no throw"; });
  // Each kind of primitive, literals too.
  t("strict s.k = 1", function () { s.k = 1; return "no throw"; });
  t("strict b.k = 1", function () { b.k = 1; return "no throw"; });
  t("strict y.k = 1", function () { y.k = 1; return "no throw"; });
  t("strict y.description = 1", function () { y.description = 1; return "no throw"; });
  t("strict (1).k = 1", function () { (1).k = 1; return "no throw"; });
  t("strict (1.5).k = 1", function () { (1.5).k = 1; return "no throw"; });
  t("strict NaN.k = 1", function () { NaN.k = 1; return "no throw"; });
  t("strict 'x'.k = 1", function () { "x".k = 1; return "no throw"; });
  // A string's own characters and length are read-only, whatever the
  // prototype holds under the same key; past the end the prototype is
  // asked.
  t("strict s.length = 1", function () { s.length = 1; return "no throw"; });
  t("strict s[0] = 'x'", function () { s[0] = "x"; return "no throw"; });
  t("strict s['1'] = 'x'", function () { s["1"] = "x"; return "no throw"; });
  t("strict s[5] = 'x'", function () { s[5] = "x"; return "no throw"; });
  t("strict s[7] = 'x', a setter", function () { s[7] = "x"; return "no throw"; });
  // What the prototype chain holds decides: a setter takes the write, a
  // getter alone or a read-only property refuses it, and a writable one
  // would be shadowed on the receiver, which cannot be.
  t("strict n.viaSetter = 7", function () { n.viaSetter = 7; return "no throw"; });
  t("strict s.viaSetter = 8", function () { s.viaSetter = 8; return "no throw"; });
  t("strict b.viaObjectSetter = 1", function () { b.viaObjectSetter = 1; return "no throw"; });
  t("strict y.viaObjectSetter = 2", function () { y.viaObjectSetter = 2; return "no throw"; });
  t("strict n.viaSetter += 1", function () { n.viaSetter += 1; return "no throw"; });
  t("strict n[setterKey] = 3", function () { n[setterKey] = 3; return "no throw"; });
  t("strict value of the assignment", function () { return n.viaSetter = 5; });
  t("strict n.getOnly = 7", function () { n.getOnly = 7; return "no throw"; });
  t("strict n.readOnly = 7", function () { n.readOnly = 7; return "no throw"; });
  t("strict n.inherited = 2", function () { n.inherited = 2; return "no throw"; });
  t("strict n[badKey] = 1", function () { n[badKey] = 1; return "no throw"; });
  // Through `this`, which strict code does not wrap.
  function assign() { this.k = 1; return "no throw"; }
  function add() { this.k += 1; return "no throw"; }
  function or() { this.k ||= 5; return "no throw"; }
  function nullish() { this.k ??= 1; return "no throw"; }
  function viaSetter() { this.viaSetter = 9; return "no throw"; }
  t("strict this.k = 1, this 's'", function () { return assign.call("s"); });
  t("strict this.k = 1, this true", function () { return assign.call(true); });
  t("strict this.k = 1, this a symbol", function () { return assign.call(sym); });
  t("strict this.k = 1, this an object", function () { return assign.call({}); });
  t("strict this.k += 1, this 0", function () { return add.call(0); });
  t("strict this.k ||= 5, this 0", function () { return or.call(0); });
  t("strict this.k ??= 1, this 0", function () { return nullish.call(0); });
  t("strict this.viaSetter = 9, this 0", function () { return viaSetter.call(0); });
  t("strict null.k = 1", function () { null.k = 1; return "no throw"; });
  t("strict, the primitives after", function () { return [n, s, s.length, b, n.k, s.k].map(String).join(" "); });
})();

(function () {
  var n = 0, s = "ab", b = true;
  t("sloppy n.k = 1", function () { n.k = 1; return n.k; });
  t("sloppy n.k++", function () { return n.k++; });
  t("sloppy s.length = 1", function () { s.length = 1; return s.length; });
  t("sloppy s[0] = 'x'", function () { s[0] = "x"; return s; });
  t("sloppy s[7] = 'x', a setter", function () { s[7] = "x"; return s; });
  t("sloppy b.k = 1", function () { b.k = 1; return b.k; });
  t("sloppy sym.k = 1", function () { sym.k = 1; return sym.k; });
  t("sloppy n.viaSetter = 7", function () { n.viaSetter = 7; return "no throw"; });
  t("sloppy n.viaObjectSetter = 3", function () { n.viaObjectSetter = 3; return "no throw"; });
  t("sloppy n.getOnly = 7", function () { n.getOnly = 7; return n.getOnly; });
  t("sloppy n.readOnly = 7", function () { n.readOnly = 7; return n.readOnly; });
  t("sloppy n[plainKey] = 1", function () { n[plainKey] = 1; return "no throw"; });
  t("sloppy n[badKey] = 1", function () { n[badKey] = 1; return "no throw"; });
  // Sloppy code wraps `this`, and the wrapper takes the property.
  function add() { this.k = 1; this.k += 1; return typeof this + " " + this.k; }
  t("sloppy this.k += 1, this 0", function () { return add.call(0); });
})();
console.log(setterLog.join(", "));
console.log(keyLog.join(", "));

// Object.assign's target goes through ToObject: a primitive target is
// assigned to through its wrapper, which is the result.
function described(wrapper) { return [typeof wrapper, String(wrapper.valueOf()), "[" + Object.keys(wrapper).join(",") + "]"].join(" "); }
t("Object.assign(1, { a: 1 })", function () { var r = Object.assign(1, { a: 1 }); return described(r) + " " + r.a; });
t("Object.assign('ab', { a: 1 })", function () { var r = Object.assign("ab", { a: 1 }); return described(r) + " " + r.a; });
t("Object.assign(true, [1])", function () { var r = Object.assign(true, [1]); return described(r) + " " + r[0]; });
t("Object.assign(sym, { a: 1 })", function () { var r = Object.assign(sym, { a: 1 }); return typeof r + " " + r.toString() + " " + r.a; });
t("Object.assign(1)", function () { return described(Object.assign(1)); });
t("Object.assign(12, 'aaa', 'bb2b', '1c')", function () { var r = Object.assign(12, "aaa", "bb2b", "1c"); return described(r) + " " + r[0] + r[1] + r[2] + r[3]; });
t("Object.assign(1, a getter that collects)", function () {
  var r = Object.assign(1, { get a() { gc(); return [1, 2, 3].join(""); }, b: 2 }, { get c() { gc(); return "c"; } });
  return described(r) + " " + r.a + r.b + r.c;
});
t("Object.assign(1, a setter on the prototype)", function () { var r = Object.assign(1, { viaSetter: 4 }); return described(r) + " " + setterLog[setterLog.length - 1]; });
t("Object.assign(null, {})", function () { return Object.assign(null, {}); });
t("Object.assign(undefined)", function () { return Object.assign(undefined); });
