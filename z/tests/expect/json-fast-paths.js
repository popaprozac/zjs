// JSON.stringify writes bytes until a unit past one appears, reads narrow
// strings' storage in place, and skips the toJSON lookup for a chain of
// ordinary objects already found without one; JSON.parse builds narrow
// strings as bytes. The edges of those paths, each against node.
var sections = [];
sections.push((function () {
var cases = [
  "plain", "quote\"back\\slash", "ctl\u0001\b\f\n\r\t", "latin é ÿ ©", "wide 中文 😀", "lone \ud800 x \udc00",
  { a: "é", b: ["x", 1, true, null, 2.5, -0, 1e21] }, [undefined, function () {}, Symbol("s")],
  { nested: { deep: [{ k: "v " }] } }, "x".repeat(300) + "é", "Ā after", 123456789, -2147483648,
];
var out = [];
for (var i = 0; i < cases.length; i++) out.push(JSON.stringify(cases[i]));
out.push(JSON.stringify({ a: [1, { b: 2 }], c: "é" }, null, 2));
out.push(JSON.stringify({ a: [1, { b: 2 }], c: "中" }, null, "\t"));
out.push(JSON.stringify({ a: 1, b: "é", c: [3] }, ["a", "b"]));
out.push(JSON.stringify({ a: 1, b: 2 }, function (k, v) { return typeof v === "number" ? "n" + v + "é" : v; }));
out.push(JSON.stringify({ x: { toJSON: function () { return "中" + "é"; } } }));
out.push(JSON.stringify("é" + "中", null, 1), JSON.stringify(["é", "中"]));
return out.join("\n");
})());
sections.push((function () {
var out = [];
var a = { x: 1 }, b = { x: 2, toJSON: function () { return "B"; } };
out.push(JSON.stringify([a, b, a]));
var calls = 0; var getterObj = {}; Object.defineProperty(getterObj, "toJSON", { get: function () { calls++; return undefined; } });
out.push(JSON.stringify([getterObj, getterObj]) + calls);
var late = [{ v: 1 }, { v: 2, get w() { Object.prototype.toJSON = function () { return "late"; }; return 3; } }, { v: 4 }];
out.push(JSON.stringify(late)); delete Object.prototype.toJSON;
class P { constructor(n) { this.n = n; } }
out.push(JSON.stringify([new P(1), new P(2)]));
P.prototype.toJSON = function () { return "P" + this.n; };
out.push(JSON.stringify([new P(3), { n: 4 }, new P(5)]));
var bare = Object.create(null); bare.q = 1; out.push(JSON.stringify([bare, bare]));
out.push(JSON.stringify({ d: new Date(0) }));
var swap = [{ s: 1 }, { s: 2 }]; var proto2 = { toJSON: function () { return "swapped"; } };
out.push(JSON.stringify(swap, function (k, v) { if (k === "0") Object.setPrototypeOf(swap[1], proto2); return v; }));
return out.join("\n");
})());
sections.push((function () {
var inputs = ['{"a":1,"b":[true,false,null],"c":"x\\u00e9\\n"}', '[1.5,-0,1e3,-12,0.001,123456789012345678]', '"\\ud83d\\ude00 wide"',
  '{"中":"文","k":"é"}', '  [ {"x" : "y"} , "z" ]  ', '"\\u0100abc"', '{"a":"' + "é".repeat(5) + '","b":"' + "中".repeat(3) + '"}',
  '[' + Array.from({length: 40}, function (_, i) { return '{"id":' + i + ',"t":"p' + i + '"}'; }).join(',') + ']', '{"bad":}', '[1,]', 'tru', '"\\x"', '"a\u0001b"'];
var out = [];
for (var i = 0; i < inputs.length; i++) { try { out.push(JSON.stringify(JSON.parse(inputs[i]))); } catch (e) { out.push(e.constructor.name); } }
var wideDoc = JSON.stringify({ s: "中é😀", n: [1, 2] }); out.push(JSON.stringify(JSON.parse(wideDoc)));
return out.join("\n");
})());
sections.push((function () {
var inputs = ['"中"', '{"k中":"v文"}', '["\\中"]', '[1,中]', '中', '"a\\"中\\\\"', '{"a":"\\u4e2d中"}', '"\\ud83d\\ude00😀"', '"é中"', '"\\"中"',
  '["x",' + '"中",'.repeat(3) + '"y"]', '"\\\\中"', ' "中" ', '"中\\n"', '"中\\u"'];
var out = [];
for (var i = 0; i < inputs.length; i++) { try { out.push(JSON.stringify(JSON.parse(inputs[i]))); } catch (e) { out.push(e.constructor.name); } }
return out.join("\n");
})());
console.log(sections.join("\n"));
