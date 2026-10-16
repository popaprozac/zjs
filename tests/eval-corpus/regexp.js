// RegExp: literals, exec results, the string methods through the
// symbol protocol, flags, and subclassing. Only what the reference
// also gets right; the rest is listed in the README.
var log = [];
var re = /a(b+)c/g;
log.push(re.source, re.flags, re.global, re.lastIndex, Object.prototype.toString.call(re), re instanceof RegExp, typeof RegExp.prototype.exec);
var m = re.exec("xabbbc abc");
log.push(m[0], m[1], m.index, m.input, m.length, re.lastIndex, JSON.stringify(re.exec("xabbbc abc")), re.exec("xabbbc abc"), re.lastIndex);
log.push("2026-09-15".replace(/(\d+)-(\d+)-(\d+)/, "$3/$2/$1"), "aaa".replace(/a/g, "b"), "x-y_z".split(/[-_]/).join(","), "abc".search(/c/), "abc".match(/b/)[0], "a1b2c3".match(/\d/g).join(""));
log.push("aBc".replace(/b/i, function (m, off, s) { return "[" + m + off + s.length + "]"; }), "café au lait".match(/\b\w+/g).length);
log.push(new RegExp(/x/g).flags, new RegExp(/x/g, "i").flags, RegExp("a+").source);
log.push(/(a)|(b)/.exec("b")[1], "abc".replace(/(x)?b/, "[$1]"), "abc".replaceAll(/b/g, "B"), "$&".replace(/\$/, "$$"), "aaa".lastIndexOf("a"), /a/y.test("ba"), /a/.test("ba"), /^a/m.test("b\na"));
try { "abc".replaceAll(/b/, "x"); } catch (e) { log.push(e instanceof TypeError); }
try { "abc".startsWith(/a/); } catch (e) { log.push(e instanceof TypeError); }
var sticky = /a/y; sticky.lastIndex = 1; log.push(sticky.test("ba"), sticky.lastIndex, sticky.test("ba"), sticky.lastIndex);
log.push(RegExp.prototype.global, RegExp.prototype.flags, RegExp[Symbol.species] === RegExp, RegExp.length);
log.push("ab".split("").join("|"), "".split(/x/).length, "abc".split(/x*/).join("|"));
class R extends RegExp { exec(s) { var r = super.exec(s); if (r) r.tagged = true; return r; } }
var rr = new R("b"); log.push(rr.test("abc"), rr instanceof RegExp, "abc".replace(rr, "X"), rr.flags);
log.join("|");
