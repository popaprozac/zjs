// `delete` of a member puts its base through ToObject before the key is
// looked at: a TypeError for null and undefined, in sloppy and strict
// code. In an optional chain a nullish base at a `?.` link ends the chain
// instead: nothing more is evaluated, nothing is deleted, and the result
// is true.
function t(label, f) {
  try { console.log(label, "->", String(f())); }
  catch (e) { console.log(label, "threw", e.name); }
}
var n = null, u, log = [];
function key(name) { log.push("key " + name); return name; }
var objKey = { toString: function () { log.push("toString"); return "zz"; } };

t("delete n.zz", function () { return delete n.zz; });
t("delete u.zz", function () { return delete u.zz; });
t("delete n['zz']", function () { return delete n["zz"]; });
t("delete u['zz']", function () { return delete u["zz"]; });
t("delete n[0]", function () { return delete n[0]; });
t("delete (n.zz)", function () { return delete (n.zz); });
t("delete ((n).zz)", function () { return delete ((n).zz); });
t("delete null.zz", function () { return delete null.zz; });
t("delete undefined.zz", function () { return delete undefined.zz; });
t("delete (void 0).zz", function () { return delete (void 0).zz; });
t("delete {}.a.b", function () { return delete ({}).a.b; });
t("delete n.a.b", function () { return delete n.a.b; });
// The key's expression is evaluated, but it is not made a property key.
t("delete u[key('a')]", function () { return delete u[key("a")]; });
t("delete n[objKey]", function () { return delete n[objKey]; });
console.log(log.join(", "));

// Any other base deletes as before.
t("delete (0).zz", function () { return delete (0).zz; });
t("delete true.zz", function () { return delete true.zz; });
t("delete 'ab'.zz", function () { return delete "ab".zz; });
t("delete Symbol().zz", function () { return delete Symbol().zz; });
t("delete {}.zz", function () { return delete ({}).zz; });
t("delete [].zz", function () { return delete [].zz; });
t("delete t.zz", function () { return delete t.zz; });
t("delete {}[objKey]", function () { var o = { zz: 1 }; return (delete o[objKey]) + " " + ("zz" in o); });
function sloppyThis() { return delete this.neverDefined; }
t("sloppy delete this.zz, this undefined", function () { return sloppyThis(); });

(function () {
  "use strict";
  var n = null, u;
  function viaThis() { return delete this.zz; }
  t("strict delete n.zz", function () { return delete n.zz; });
  t("strict delete u['zz']", function () { return delete u["zz"]; });
  t("strict delete this.zz, this undefined", function () { return viaThis(); });
  t("strict delete this.zz, this null", function () { return viaThis.call(null); });
  t("strict delete this.zz, this 0", function () { return viaThis.call(0); });
  t("strict delete this.zz, this an object", function () { var o = { zz: 1 }; return viaThis.call(o) + " " + ("zz" in o); });
  t("strict delete n?.zz", function () { return delete n?.zz; });
  t("strict delete frozen?.a", function () { return delete Object.freeze({ a: 1 })?.a; });
})();

// Optional chains.
log = [];
var o = { a: 1, b: { c: 2, d: 3, e: 4 }, f: function () { return o.b; }, g: null };
t("delete n?.zz", function () { return delete n?.zz; });
t("delete u?.[key('skipped')]", function () { return delete u?.[key("skipped")]; });
t("delete n?.a.b", function () { return delete n?.a.b; });
t("delete (n?.a.b)", function () { return delete (n?.a.b); });
t("delete (n?.a).b", function () { return delete (n?.a).b; });
t("delete o?.a", function () { return (delete o?.a) + " " + ("a" in o); });
t("delete o?.['b'].c", function () { return (delete o?.["b"].c) + " " + ("c" in o.b); });
t("delete o.b?.d", function () { return (delete o.b?.d) + " " + ("d" in o.b); });
t("delete o.f?.().e", function () { return (delete o.f?.().e) + " " + ("e" in o.b); });
t("delete o.g?.().e", function () { return delete o.g?.().e; });
t("delete o.g?.x[key('skipped')]", function () { return delete o.g?.x[key("skipped")]; });
t("delete o?.[key('evaluated')]", function () { return delete o?.[key("evaluated")]; });
t("delete o.zz?.a.b", function () { return delete o.zz?.a.b; });
t("delete o.zz.a", function () { return delete o.zz.a; });
t("delete o.b?.zz.a", function () { return delete o.b?.zz.a; });
t("delete frozen?.a", function () { return delete Object.freeze({ a: 1 })?.a; });
t("typeof (delete n?.a)", function () { return typeof (delete n?.a); });
t("delete o?.#x", function () { return eval("class Q { #x; m(o) { return delete o?.#x; } }"); });
console.log(log.join(", "));
