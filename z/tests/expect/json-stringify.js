// JSON.stringify: every value kind, keys skipped for values with no JSON form, indentation, escapes, surrogates.
var out = [];
out.push(JSON.stringify({ a: 1, b: undefined, c: function () {}, d: Symbol("s"), e: "x", f: null, g: [undefined, function () {}, 3], h: -0, i: 1e21, j: -2147483648, k: 2147483647, l: 0.1, m: NaN, n: Infinity }));
out.push(JSON.stringify({ skip: undefined }), JSON.stringify({ a: undefined, b: 2 }), JSON.stringify({ a: 1, b: undefined }));
out.push(JSON.stringify("q\"b\\n\n\t\u0001\u001f/ "), JSON.stringify("\ud800"), JSON.stringify("\udc00x"), JSON.stringify("😀"), JSON.stringify("éÿ"));
out.push(JSON.stringify({ nested: { deep: [1, { x: [] }, {}] }, t: true, f: false }, null, 2));
out.push(JSON.stringify([1, [2, [3]]], null, "--"));
out.push(JSON.stringify({ a: 1, b: { toJSON: function (k) { return "key:" + k; } } }));
out.push(JSON.stringify({ a: 1, b: 2, c: { a: 3, d: 4 } }, ["a", "c"]));
out.push(JSON.stringify({ a: 1, b: "two" }, function (k, v) { return typeof v === "number" ? v * 10 : v; }));
out.push(JSON.stringify(new Date(0)), JSON.stringify([new Number(3), new String("s"), new Boolean(false)]));
var wide = { "ākey": "valĂ" }; out.push(JSON.stringify(wide));
try { var cyc = {}; cyc.self = cyc; JSON.stringify(cyc); } catch (e) { out.push(e.constructor.name); }
out.push(String(JSON.stringify(undefined)), String(JSON.stringify(function () {})), JSON.stringify(null), JSON.stringify(12));
console.log(out.join("\n"));
