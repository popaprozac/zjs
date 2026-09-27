// JSON over object shapes: stringify reading keys from the shape and
// values from slots while getters and toJSON reshape objects mid-walk;
// parse reusing class transitions, with its number and literal edges.
var out = [];
var o1 = { a: 1, get b() { delete this.c; this.z = 9; return 2; }, c: 3, d: 4 };
out.push(JSON.stringify(o1));
var o2 = { a: 1, get b() { this.a = 100; this.d = "late"; return "B"; }, d: 5 };
out.push(JSON.stringify(o2));
var o3 = { x: 1, y: 2 }; Object.defineProperty(o3, "hidden", { value: 3, enumerable: false }); o3[Symbol("s")] = 4; o3.z = 5;
out.push(JSON.stringify(o3));
out.push(JSON.stringify({ b: 1, 2: "two", a: 2, 1: "one", "10": "ten" }));
var dict = {}; for (var i = 0; i < 80; i++) dict["k" + i] = i; delete dict.k3; delete dict.k70; dict.last = true;
out.push(JSON.stringify(dict).length, JSON.stringify(dict).slice(0, 40));
var arr = [1, , 3]; Object.defineProperty(arr, 1, { get: function () { return "got"; }, enumerable: true }); arr.length = 5;
out.push(JSON.stringify(arr), JSON.stringify([, , "x"]));
function Point(x) { this.x = x; } Point.prototype.toJSON = function () { return "P" + this.x; };
out.push(JSON.stringify({ p: new Point(3), q: [new Point(4)] }));
var withOwnToJSON = { toJSON: function (key) { return "key=" + key; } };
out.push(JSON.stringify({ w: withOwnToJSON }), JSON.stringify(withOwnToJSON));
out.push(JSON.stringify({ a: [1, { b: 2 }], c: "x" }, function (k, v) { return typeof v === "number" ? v * 10 : v; }));
out.push(JSON.stringify({ a: 1, b: 2, c: { a: 3, d: 4 } }, ["a", "c"]));
out.push(JSON.stringify({ a: [1, { b: 2 }], c: {} }, null, 2));
out.push(JSON.stringify({ f: function () {}, u: undefined, s: Symbol("q"), n: null, nan: NaN, inf: -Infinity, neg: -0, d: new Date(0) }));
class C { constructor() { this.m = 1; } get g() { return 2; } } out.push(JSON.stringify(new C()));
out.push(JSON.stringify(new Map([[1, 2]])), JSON.stringify(Object.create({ inherited: 1 }, { own: { value: 2, enumerable: true } })));
var cyc = { a: 1 }; cyc.self = cyc; try { JSON.stringify(cyc); } catch (e) { out.push(e.constructor.name); }
var thrower = { a: 1, get b() { throw new RangeError("stop"); } }; try { JSON.stringify(thrower); } catch (e) { out.push(e.message); }
var shapeA = []; for (var j = 0; j < 3; j++) shapeA.push({ id: j, tag: "t" + j, ok: j % 2 === 0, sub: { v: j } }); out.push(JSON.stringify(shapeA));
out.push(JSON.stringify("str \ud800x"), JSON.stringify({ "é": "中" }));
console.log(out.join("\n"));

out = [];
function show(text) { try { var v = JSON.parse(text); out.push(JSON.stringify(v) + (typeof v === "number" && Object.is(v, -0) ? "(-0)" : "")); } catch (e) { out.push(e.constructor.name); } }
["{\"a\":1,\"a\":2,\"b\":3}", "{\"2\":\"x\",\"b\":1,\"1\":\"y\"}", "{\"__proto__\":{\"p\":1},\"q\":2}", "-0", "0", "-12", "123456789012345", "1234567890123456789", "12345678901234567890123", "0.1", "1e5", "-1.5E-3", "01", "-", "1.", ".5", "+1", "tru", "true", "nul", "null", "false ", "fals", "[1,2,,3]", "[1,2,3,]", "{\"a\":1,}", "\"\\u00e9\\u4e2d\\ud83d\\ude00\"", "[true,false,null,-7,7.25]", "  {\"x\" : [ 1 , { \"y\" : null } ] }  "].forEach(show);
var p = JSON.parse("{\"__proto__\":{\"p\":1},\"q\":2}"); out.push(Object.keys(p).join(","), p.p, Object.getPrototypeOf(p) === Object.prototype);
var many = "{" + Array.from({ length: 90 }, function (_, i) { return "\"k" + i + "\":" + i; }).join(",") + "}"; var m = JSON.parse(many); out.push(Object.keys(m).length, m.k89, Object.keys(m)[42]);
var rep = "[" + Array.from({ length: 6 }, function (_, i) { return "{\"id\":" + i + ",\"tag\":\"t" + i + "\",\"ok\":" + (i % 2 === 0) + "}"; }).join(",") + "]";
var r = JSON.parse(rep); out.push(r.map(function (o) { return Object.keys(o).join("") + o.id + o.tag + o.ok; }).join("|"));
out.push(JSON.stringify(JSON.parse(rep, function (k, v) { return k === "tag" ? v.toUpperCase() : (k === "ok" ? undefined : v); })));
var a = JSON.parse("{\"b\":1,\"a\":2}"), b = JSON.parse("{\"a\":2,\"b\":1}"); out.push(Object.keys(a).join(""), Object.keys(b).join(""));
console.log(out.join("\n"));
