// ToString(Number) and toExponential() give the shortest decimal that
// reads back as the double, the nearest one if several do. At a power of
// two the gap below is half the gap above, so that decimal can lie past
// the nearest one, above the double (2^-24 is 5.960464477539063e-8).
// Each value prints through String, toExponential of its negation,
// JSON.stringify, and a template literal; every power of two and a seeded
// sweep of doubles print as one hash each.
var log = [];
function forms(x) { return String(x) + " " + (-x).toExponential() + " " + JSON.stringify(x) + " " + `${x}`; }
function hash(h, text) { for (var i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619); return h; }
[-1074, -1073, -1023, -1022, -1021, -1017, -1007, -957, -549, -383, -97, -44, -26, -25, -24, -23, -1, 0, 53, 54, 69, 70, 89, 122, 594, 976, 1022, 1023].forEach(function (k) {
  log.push("2^" + k + ": " + forms(2 ** k));
});
[2.225073858507201e-308, 2.225073858507202e-308, 1.7976931348623157e308, 1e21, 999999999999999900000, 1e-7, 0.000001, 0.0000001234,
 1e15 + 0.5, 0.1 + 0.2, 1 / 3, 4.35, 1959361107016076.2, -205320665442184.62, 128012831775210.12].forEach(function (x) { log.push(forms(x)); });
var h = -2128831035;
for (var k = -1074; k <= 1023; k++) h = hash(h, forms(2 ** k));
log.push("every power of two: " + (h >>> 0).toString(16));
var view = new DataView(new ArrayBuffer(8));
var seed = 0x2545F491 | 0;
function next() { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return seed >>> 0; }
h = -2128831035;
var count = 0;
while (count < 5000) {
  view.setUint32(0, next()); view.setUint32(4, next());
  var x = view.getFloat64(0);
  if (x !== x || x === Infinity || x === -Infinity) continue;
  h = hash(h, forms(x));
  count++;
}
log.push("5000 seeded doubles: " + (h >>> 0).toString(16));
console.log(log.join("\n"));
