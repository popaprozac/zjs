// RegExp replace builds its result from the subject's storage, and exec
// skips the lookup of exec and reads lastIndex and the flags from known
// slots for a regular expression of a recorded class. The edges of those
// paths, each against node.
var s = "a1b22c333 é 中 d4444";
var out = [s.replace(/\d+/g, "#"), s.replace(/\d+/, "#"), s.replace(/(\d)(\d*)/g, "[$1|$2]"), s.replace(/\d+/g, function (m, off) { return "<" + m.length + "@" + off + ">"; }),
  s.replace(/x/g, "y"), "aaa".replace(/a*/g, "-"), "".replace(/^/g, "S"), s.replace(/(?<d>\d)/g, "{$<d>}"), s.replace(/é/g, "中"), s.replace(/中/g, "e"),
  "abc".replace(/b/g, "$`$'$&$$"), "x".repeat(300).replace(/x{100}/g, "Y"), "😀a😀".replace(/(?:)/gu, "_"), s.replace(/\d+/g, "é")];
console.log(out.join("\n"));
var out = [];
var re = /a(\d)/g; var s = "a1 a2 a3";
var m; while ((m = re.exec(s)) !== null) out.push(m[1] + "@" + m.index);
out.push(s.replace(/a(\d)/g, "<$1>"), JSON.stringify(s.match(/a\d/g)));
var own = /a(\d)/g; own.exec = function (x) { out.push("own exec"); return null; }; out.push(s.replace(own, "X"));
var saved = RegExp.prototype.exec; var calls = 0;
RegExp.prototype.exec = function (x) { calls++; return saved.call(this, x); };
out.push(s.replace(/a(\d)/g, "[$1]"), calls);
RegExp.prototype.exec = saved;
out.push(s.replace(/a(\d)/g, "{$1}"));
var sub = /a/g; Object.setPrototypeOf(sub, { exec: function () { return null; }, get flags() { return "g"; }, get global() { return true; } });
try { out.push(RegExp.prototype[Symbol.replace].call(sub, s, "Z")); } catch (e) { out.push(e.constructor.name); }
out.push(/(\d+)/.test("x12"), /q/.test("x"));
console.log(out.join("\n"));
var li = /b/g; li.lastIndex = "2"; var r1 = li.exec("abab"); var fr = Object.freeze(/c/g); var fe; try { fr.exec("c"); } catch (e) { fe = e.constructor.name; }
var sticky = /x/y; sticky.lastIndex = 1; var r2 = sticky.exec("ax"); var big = /z/g; big.lastIndex = 2 ** 40; var r3 = big.exec("z");
console.log([r1 && r1.index, li.lastIndex, fe, r2 && r2.index, sticky.lastIndex, r3, big.lastIndex].join(","));

// The flags the replace, split, match, and matchAll algorithms read come
// from a regular expression's bits while RegExp.prototype holds its own
// accessors and the object has none of their names; any change is seen.
var out = [];
var t = "Aa\nab-AB";
out.push(t.replace(/a/gi, "_"), t.replace(/^a/gim, "^"), JSON.stringify(t.split(/b/iy)), JSON.stringify(t.match(/a./gs)), JSON.stringify([...t.matchAll(/a/dgi)].map(function (m) { return m.indices[0][0]; })), "😀😀".replace(/(?:)/gu, "."), "😀".replace(/[😀]/gv, "v"));
var ownFlags = /a/g; Object.defineProperty(ownFlags, "flags", { value: "" }); out.push(t.replace(ownFlags, "F"), t.replace(ownFlags, "F"));
var ownGlobal = /a/gi; Object.defineProperty(ownGlobal, "global", { value: false }); out.push(t.replace(ownGlobal, "G"), t.replace(ownGlobal, "G"), ownGlobal.flags);
// One in dictionary mode keeps its class id when it gains a property.
var dict = /a/g; for (var k = 0; k < 40; k++) dict["p" + k] = k; for (var k = 0; k < 40; k++) delete dict["p" + k];
out.push(t.replace(dict, "1"), t.replace(dict, "1"));
Object.defineProperty(dict, "flags", { value: "" }); out.push(t.replace(dict, "2"), t.replace(dict, "3"));
var reads = [];
var globalDescriptor = Object.getOwnPropertyDescriptor(RegExp.prototype, "global");
Object.defineProperty(RegExp.prototype, "global", { get: function () { reads.push("global"); return false; }, configurable: true });
out.push(t.replace(/a/g, "N"), reads.join());
Object.defineProperty(RegExp.prototype, "global", globalDescriptor);
out.push(t.replace(/a/g, "R"));
// The accessor first installed is out of the prototype now; a collection
// must not let a getter defined after it pass for it.
if (typeof gc === "function") gc();
Object.defineProperty(RegExp.prototype, "global", { get: function () { reads.push("again"); return false; }, configurable: true });
out.push(t.replace(/a/g, "C"));
Object.defineProperty(RegExp.prototype, "global", globalDescriptor);
var flagsDescriptor = Object.getOwnPropertyDescriptor(RegExp.prototype, "flags");
Object.defineProperty(RegExp.prototype, "flags", { get: function () { reads.push("flags"); return ""; }, configurable: true });
out.push(t.replace(/a/g, "I"), JSON.stringify(t.match(/a/g)), reads.join());
Object.defineProperty(RegExp.prototype, "flags", flagsDescriptor);
delete RegExp.prototype.ignoreCase;
out.push(t.replace(/a/gi, "D"), /a/gi.flags);
console.log(out.join("\n"));

// lastIndex is stored straight into its slot for a regular expression of
// the recorded class; one made read-only after use is no longer of it.
var out = [];
var ro = /a/g; out.push("aa".replace(ro, "b"), "a-a".split(/-/).length, ro.exec("aa").index, ro.lastIndex, typeof ro.lastIndex);
Object.defineProperty(ro, "lastIndex", { writable: false });
function attempt(f) { try { return String(f()); } catch (e) { return e.constructor.name; } }
out.push(attempt(function () { return "aa".replace(ro, "b"); }), attempt(function () { return ro.exec("aa"); }), ro.lastIndex);
var st = /a/y; st.lastIndex = 1; st.test("ab"); out.push(st.lastIndex); Object.defineProperty(st, "lastIndex", { writable: false, value: 1 }); out.push(attempt(function () { return st.test("ab"); }));
console.log(out.join("\n"));
