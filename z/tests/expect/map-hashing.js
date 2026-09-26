// Map and Set keys of every kind, including numbers that differ only in
// their high bits, find their entries.
var out = [];
var m = new Map();
var keys = [0, -0, 1, 2, 1024, 1048576, 2 ** 40, 2 ** 52, -1, 0.5, 1e-300, NaN, Infinity, -Infinity, "k", "", "1", true, false, null, undefined];
var sym = Symbol("s"), obj = {}, fn = function () {};
keys.push(sym, obj, fn);
keys.forEach(function (k, i) { m.set(k, i); });
out.push("size " + m.size);
out.push(keys.map(function (k) { return m.get(k); }).join(","));
out.push("zeros " + m.get(0) + " " + m.get(-0) + " nan " + m.get(NaN) + " one-as-string " + m.get("1") + " one " + m.get(1));
var s = new Set();
for (var i = 0; i < 5000; i++) s.add(i * 1024);
var hits = 0;
for (var j = 0; j < 5000; j++) if (s.has(j * 1024)) hits++;
out.push("set " + s.size + " " + hits + " " + s.has(1023) + " " + s.has(5000 * 1024));
for (var d = 0; d < 5000; d += 2) s.delete(d * 1024);
out.push("after delete " + s.size + " " + s.has(2 * 1024) + " " + s.has(3 * 1024));
var order = [];
new Map([[3, "c"], [1, "a"], [2, "b"]]).forEach(function (v, k) { order.push(k + v); });
out.push("order " + order.join(" "));
console.log(out.join("\n"));
