// `a[i].name` reads the element and the name in one instruction; every
// other case reads them as the two reads would.
var shapes = [{ v: 1 }, { a: 1, v: 2 }, { a: 1, b: 2, v: 3 }, { a: 1, b: 2, c: 3, v: 4 }, { w: 9 }];
var total = 0;
for (var round = 0; round < 3; round++) {
  for (var j = 0; j < shapes.length; j++) total += shapes[j].v === undefined ? 100 : shapes[j].v;
}
console.log(total);

var list = [{ x: 1 }, , { get x() { return "getter"; } }, "str", 7, [5, 6], null];
var seen = [];
for (var k = 0; k < 6; k++) if (k !== 1) seen.push(String(list[k].x));
console.log(seen.join(), list[3].length, list[5].length, list[4].toFixed === Number.prototype.toFixed);
try { list[6].x; } catch (e) { console.log(e instanceof TypeError); }
try { var none; none[0].x; } catch (e) { console.log(e instanceof TypeError); }
try { list[1].x; } catch (e) { console.log(e instanceof TypeError); }

// Keys that are not small integers, objects that are not arrays.
var byName = { first: { x: "named" } }, key = "first";
var arrayLike = { 0: { x: "like" }, length: 1 };
var typed = [{ x: 1.5 }];
console.log(byName[key].x, arrayLike[0].x, typed[0.0].x, typed["0"].x, [[{ x: "deep" }]][0][0].x);
Array.prototype[3] = { x: "inherited" };
var holey = [{ x: 0 }];
console.log(holey[3].x);
delete Array.prototype[3];

// Order: the array, then the key, then the reads.
var log = [];
var trace = { get arr() { log.push("arr"); return [{ x: "o" }]; } };
function idx() { log.push("idx"); return 0; }
console.log(trace.arr[idx()].x, log.join());

// A leaf callback reading through elements.
var rows = [[{ n: 3 }], [{ n: 4 }], [{ n: 5 }]];
console.log(rows.map(function (r) { return r[0].n * 2; }).join(), rows.reduce(function (s, r) { return s + r[0].n; }, 0));
