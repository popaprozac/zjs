// RegExp replace builds its result from the subject's storage, and exec
// skips the lookup of exec and reads lastIndex and the flags from known
// slots for a regular expression of a recorded class. The edges of those
// paths, each against node.
var s = "a1b22c333 é 中 d4444";
var out = [s.replace(/\d+/g, "#"), s.replace(/\d+/, "#"), s.replace(/(\d)(\d*)/g, "[$1|$2]"), s.replace(/\d+/g, function (m, off) { return "<" + m.length + "@" + off + ">"; }),
  s.replace(/x/g, "y"), "aaa".replace(/a*/g, "-"), "".replace(/^/g, "S"), s.replace(/(?<d>\d)/g, "{$<d>}"), s.replace(/é/g, "中"), s.replace(/中/g, "e"),
  "abc".replace(/b/g, "$`$'$&$$"), "x".repeat(300).replace(/x{100}/g, "Y"), "😀a😀".replace(/(?:)/gu, "_"), s.replace(/\d+/g, "é")];
console.log(out.join("\n"));
var out = [];
var re = /a(\d)/g; var s = "a1 a2 a3";
var m; while ((m = re.exec(s)) !== null) out.push(m[1] + "@" + m.index);
out.push(s.replace(/a(\d)/g, "<$1>"), JSON.stringify(s.match(/a\d/g)));
var own = /a(\d)/g; own.exec = function (x) { out.push("own exec"); return null; }; out.push(s.replace(own, "X"));
var saved = RegExp.prototype.exec; var calls = 0;
RegExp.prototype.exec = function (x) { calls++; return saved.call(this, x); };
out.push(s.replace(/a(\d)/g, "[$1]"), calls);
RegExp.prototype.exec = saved;
out.push(s.replace(/a(\d)/g, "{$1}"));
var sub = /a/g; Object.setPrototypeOf(sub, { exec: function () { return null; }, get flags() { return "g"; }, get global() { return true; } });
try { out.push(RegExp.prototype[Symbol.replace].call(sub, s, "Z")); } catch (e) { out.push(e.constructor.name); }
out.push(/(\d+)/.test("x12"), /q/.test("x"));
console.log(out.join("\n"));
var li = /b/g; li.lastIndex = "2"; var r1 = li.exec("abab"); var fr = Object.freeze(/c/g); var fe; try { fr.exec("c"); } catch (e) { fe = e.constructor.name; }
var sticky = /x/y; sticky.lastIndex = 1; var r2 = sticky.exec("ax"); var big = /z/g; big.lastIndex = 2 ** 40; var r3 = big.exec("z");
console.log([r1 && r1.index, li.lastIndex, fe, r2 && r2.index, sticky.lastIndex, r3, big.lastIndex].join(","));
