var log = [];
var seen = "";
for (var v of [1, 2, 3]) seen += v;
for (var ch of "ab") seen += ch;
for (const pairItem of [[0, "x"]]) seen += pairItem[0] + pairItem[1];
log.push(seen);
var custom = { [Symbol.iterator]: function () { var n = 0; return { next: function () { n++; return n <= 3 ? { value: n * 10, done: false } : { value: undefined, done: true }; } }; } };
var total = 0;
for (var x of custom) total += x;
log.push(total, [...custom].join(), Array.from(custom).join(), Math.max(...custom), Array.from("abc").join(), Array.from({ length: 2, 0: "p", 1: "q" }).join(), Array.from([1, 2], function (v, i) { return v * 10 + i; }).join(), Array.of(7, 8).length);
var closed = 0;
var closable = { [Symbol.iterator]: function () { return { next: function () { return { value: 1, done: false }; }, return: function () { closed++; return {}; } }; } };
for (var y of closable) { break; }
outer: for (var a of [1]) { for (var b of closable) { continue outer; } }
function early() { for (var c of closable) { return "ret"; } }
early();
log.push(closed);
var it = [10, 20][Symbol.iterator]();
var first = it.next();
log.push(first.value, first.done, it.next().value, it.next().done, it.next().done, Object.prototype.toString.call(it), typeof it[Symbol.iterator], it[Symbol.iterator]() === it);
var keys = "";
for (var k of [5, 6].keys()) keys += k;
var entries = "";
for (var pair of ["a", "b"].entries()) entries += pair.join(":") + ";";
log.push(keys, entries, [..."hi", ...[1, [2]], 3].length, [...[]].length);
function spreadArgs() { return arguments.length + ":" + Array.prototype.join.call(arguments, "-"); }
log.push(spreadArgs(...[1, 2], 3, ...custom), Math.max.apply(null, [...custom]), new Array(...[3]).length, new (function (a, b) { this.s = a + b; })(...[4, 5]).s);
var caught = [];
try { for (var z of 5) {} } catch (e) { caught.push(e.name); }
try { [...{}]; } catch (e) { caught.push(e.name); }
try { for (var w of { [Symbol.iterator]: function () { return 1; } }) {} } catch (e) { caught.push(e.name); }
try { Array.from(null); } catch (e) { caught.push(e.name); }
log.push(caught.join());
log.join("|");
