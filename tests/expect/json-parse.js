// JSON.parse: every value kind, escapes, wide strings, repeated and new keys, deep nesting, collections in between, errors.
var out = [];
var text = '{"a":1,"b":[true,false,null,-0,1e3,-2.5e-3,"s"],"c":{"d":"\\u00e9\\u0101\\ud83d\\ude00","e":"\\"\\\\\\/\\b\\f\\n\\r\\t"},"a2":[],"":{}}';
out.push(JSON.stringify(JSON.parse(text)));
var many = []; for (var i = 0; i < 200; i++) many.push('{"key' + i + '":' + i + ',"shared":"v' + i + '"}');
var parsed = JSON.parse("[" + many.join(",") + "]");
if (typeof gc === "function") gc();
out.push(parsed.length + " " + parsed[199].key199 + " " + parsed[5].shared + " " + Object.keys(parsed[7]).join(","));
var deep = ""; for (var d = 0; d < 100; d++) deep += '{"n":'; deep += "0"; for (d = 0; d < 100; d++) deep += "}";
var node = JSON.parse(deep); var depth = 0; while (typeof node === "object") { node = node.n; depth++; } out.push("depth " + depth);
["{", '{"a" 1}', '{"a":}', "[1,]", '"\\x"', '{"a":1,}', "tru", "01", '"\u0001"'].forEach(function (bad) { try { JSON.parse(bad); out.push("parsed " + bad); } catch (e) { out.push(e.constructor.name); } });
out.push(JSON.stringify(JSON.parse('{"x":{"y":2}}', function (k, v) { return typeof v === "number" ? v + 1 : v; })));
console.log(out.join("\n"));
