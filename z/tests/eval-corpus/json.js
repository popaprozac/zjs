var log = [];
log.push(JSON.stringify({ a: 1, b: "two", c: [true, null, undefined, function () {}], d: { e: undefined, f: -0, g: 1e21, h: NaN, i: Infinity } }));
log.push(JSON.stringify("q\"uo\\te\n\t" + String.fromCharCode(1)), JSON.stringify(undefined), JSON.stringify(function () {}), JSON.stringify(null), JSON.stringify([undefined, , 3]), JSON.stringify({ toJSON: function (k) { return "key:" + k; } }), JSON.stringify(new Number(3)), JSON.stringify(new String("s")), JSON.stringify(new Boolean(false)));
log.push(JSON.stringify({ a: 1, b: 2, c: 3 }, ["c", "a"]), JSON.stringify({ a: 1, b: [1, 2] }, function (k, v) { return typeof v === "number" ? v * 10 : v; }), JSON.stringify([1, { x: [] }], null, 2), JSON.stringify({ a: 1 }, null, "--"), JSON.stringify({ a: 1 }, null, 20).length, JSON.stringify({}, null, 4), JSON.stringify([], null, 4));
var parsed = JSON.parse('{"num": -12.5e1, "str": "a\\\\u0041\\\\n", "arr": [1, [2, {}], false, null], "nested": {"k": true}, "": 0}');
log.push(parsed.num, parsed.str, parsed.arr.length, parsed.arr[1][1] instanceof Object, parsed.arr[2], parsed.arr[3], parsed.nested.k, parsed[""], Object.keys(parsed).join(), JSON.parse("[]").length, JSON.parse(" 42 "), JSON.parse("true"), JSON.parse("null"));
log.push(JSON.parse('{"a": [1, 2], "b": 3}', function (k, v) { return typeof v === "number" ? v + 1 : v; }).a.join() + ";" + JSON.parse('{"drop": 1, "keep": 2}', function (k, v) { return k === "drop" ? undefined : v; }).drop);
var cycle = {}; cycle.self = cycle;
var errors = [];
try { JSON.stringify(cycle); } catch (e) { errors.push(e.name); }
try { JSON.parse("{bad}"); } catch (e) { errors.push(e.name); }
try { JSON.parse("[1,]"); } catch (e) { errors.push(e.name); }
try { JSON.parse(""); } catch (e) { errors.push(e.name); }
log.push(errors.join(), Object.prototype.toString.call(JSON), typeof JSON.parse, JSON.stringify.length);
log.join("|");
