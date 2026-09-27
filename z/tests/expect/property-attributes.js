// Property attributes kept by hidden classes, dictionaries, and array
// element tables: defineProperty between data and accessor forms,
// freeze and seal, descriptors, class prototypes, cached writes after a
// freeze, dictionary-mode objects, and array elements redefined,
// deleted and re-added, and cut off by length.
"use strict";
var out = [];
function d(o, k) { var x = Object.getOwnPropertyDescriptor(o, k); return x ? JSON.stringify(x, function (key, v) { return typeof v === "function" ? "fn" : v; }) : "none"; }
function tryIt(f) { try { return String(f()); } catch (e) { return e.constructor.name; } }
var a = { x: 1, y: 2, z: 3 };
Object.defineProperty(a, "y", { enumerable: false });
out.push(Object.keys(a).join(","), d(a, "y"), a.y);
Object.defineProperty(a, "x", { writable: false });
out.push(tryIt(function () { a.x = 5; return a.x; }), d(a, "x"));
Object.defineProperty(a, "z", { get: function () { return "getter"; }, configurable: true });
out.push(a.z, d(a, "z"));
Object.defineProperty(a, "z", { value: "data again", writable: true });
out.push(a.z, d(a, "z"), Object.keys(a).join(","));
var b = { x: 1, y: 2, z: 3 }; Object.defineProperty(b, "y", { enumerable: false });
out.push(Object.keys(b).join(","));
var shapes = []; for (var i = 0; i < 4; i++) { var o = { p: i, q: i }; if (i % 2) Object.defineProperty(o, "p", { enumerable: false }); shapes.push(Object.keys(o).join("")); } out.push(shapes.join("|"));
function writeX(o, v) { o.x = v; return o.x; }
var c = { x: 1 }; for (var j = 0; j < 5; j++) writeX(c, j); Object.freeze(c);
out.push(tryIt(function () { return writeX(c, 99); }), c.x, Object.isFrozen(c), Object.isSealed(c));
var s = { m: 1, n: 2 }; Object.seal(s); s.m = 10; out.push(s.m, tryIt(function () { delete s.n; return "deleted"; }), Object.isSealed(s), Object.isFrozen(s), d(s, "n"));
class K { method() { return 1; } get acc() { return 2; } static st() {} }
out.push(Object.keys(K.prototype).length, d(K.prototype, "method"), d(K.prototype, "acc"), Object.getOwnPropertyNames(K.prototype).join(","), new K().method(), new K().acc);
var forin = []; for (var key in new K()) forin.push(key); out.push(forin.length);
var big = {}; for (var k = 0; k < 70; k++) big["k" + k] = k;
Object.defineProperty(big, "k5", { enumerable: false }); Object.defineProperty(big, "k69", { writable: false });
out.push(Object.keys(big).length, d(big, "k5"), tryIt(function () { big.k69 = 0; return big.k69; }), tryIt(function () { big.k68 = 7; return big.k68; }));
Object.freeze(big); out.push(Object.isFrozen(big), tryIt(function () { big.k1 = 0; return "wrote"; }));
var arr = [1, 2, 3, 4];
Object.defineProperty(arr, 1, { enumerable: false });
out.push(Object.keys(arr).join(","), JSON.stringify(arr), d(arr, 1));
delete arr[1]; arr[1] = "back"; out.push(Object.keys(arr).join(","), d(arr, 1));
Object.defineProperty(arr, 3, { writable: false, configurable: true }); arr.length = 3; arr[3] = "new"; out.push(d(arr, 3), arr.length);
var fz = Object.freeze([5, 6]); out.push(tryIt(function () { fz[0] = 9; return fz[0]; }), tryIt(function () { fz.push(1); }), Object.isFrozen(fz), d(fz, 0));
function tag(strs) { return Object.isFrozen(strs) + ":" + d(strs, 0) + ":" + Object.isFrozen(strs.raw) + ":" + strs.raw[0]; }
out.push(tag`a${1}b`);
var obj2 = Object.create(null, { hidden: { value: 1, enumerable: false }, shown: { value: 2, enumerable: true, writable: true } });
out.push(Object.keys(obj2).join(","), JSON.stringify(obj2), d(obj2, "hidden"));
var props = Object.getOwnPropertyDescriptors({ get g() { return 1; }, v: 2 }); out.push(Object.keys(props).join(","), typeof props.g.get, props.v.writable);
console.log(out.join("\n"));
