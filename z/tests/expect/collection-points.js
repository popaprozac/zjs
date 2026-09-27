// Values a builtin holds while JavaScript runs, or while a return
// collects, stay alive: the keys a JSON.parse reviver walks, the error a
// derived constructor's bad return raises, and the promise of an async
// function that returns before its caller has it. The expectation runner
// also runs every case with a collection at each safe point, which is
// where these were lost.
var revived = JSON.parse('[{"id":0,"tag":"t0"},{"id":1,"tag":"t1"},{"id":2,"tag":"t2"}]', function (k, v) {
  var churn = [];
  for (var i = 0; i < 20; i++) churn.push({ k: k + i });
  return k === "tag" ? v.toUpperCase() : v;
});
console.log(JSON.stringify(revived));
class Base { constructor() { this.b = 1; } }
class Derived extends Base { constructor() { super(); var a = { x: 1 }, b = [a]; return 5; } }
var kinds = [];
for (var n = 0; n < 3; n++) {
  try { new Derived(); } catch (e) { kinds.push(e.constructor.name + ":" + (e instanceof TypeError)); }
}
console.log(kinds.join(","));
var settled = Promise.resolve("n");
(async function () { var t = { y: [1, 2] }; return settled; })().then(function (v) { console.log("async returned", v); });
(async function () { return 7; })().then(function (v) { console.log("async returned", v); });
// Names interned and then unreachable leave the atom table when they are
// collected; the names still in use are found again by their text.
var keep = {};
for (var i = 0; i < 300; i++) keep["kept" + i] = i;
for (var round = 0; round < 40; round++) {
  var gone = {};
  for (var j = 0; j < 400; j++) gone["gone" + round + "_" + j] = j;
}
var found = 0;
for (var i = 0; i < 300; i++) if (keep["kept" + i] === i) found++;
var again = {};
for (var j = 0; j < 400; j++) again["gone7_" + j] = j * 2;
var sum = 0;
for (var j = 0; j < 400; j++) sum += again["gone7_" + j];
console.log(found, sum, Object.keys(keep).length, Object.keys(again)[399]);
// A global's name when nothing defines it; the object `new` makes for a
// builtin while an argument's conversion runs; strings a builtin
// converts before running a valueOf; a result under construction; a
// flag string made for matchAll; a TypeError raised before an iterator
// is closed.
try { neverDefinedAnywhere; } catch (e) { console.log(String(e)); }
var wrapped = new String({ valueOf: function () { var junk = [{}, {}]; return "wrapped"; }, toString: undefined });
console.log(wrapped.indexOf("p"), wrapped.constructor === String, wrapped.length);
var churning = { valueOf: function () { var junk = [{}, [1, 2]]; return 2; } };
console.log("abcdef".slice(churning, 4), "abcdef".substring(1, churning), "abcabc".indexOf("c", churning));
var entries = Object.fromEntries([[{ toString: function () { var junk = {}; return "k1"; } }, "v1"], ["k2", "v2"]]);
console.log(JSON.stringify(entries));
var ms = [];
for (var m of { toString: function () { var junk = [{}]; return "a1b2c3"; } }.toString().matchAll(/[0-9]/g)) ms.push(m[0]);
console.log(ms.join(""), [..."x1y2".matchAll(/\d/g)].length);
var closes = 0;
var bad = {};
bad[Symbol.iterator] = function () { return { next: function () { return { value: 1, done: false }; }, return: function () { closes++; var junk = [{}, {}]; return {}; } }; };
try { new Map(bad); } catch (e) { console.log(e.constructor.name, closes); }
