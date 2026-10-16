var out = [];
out.push(Number("12.5"), Number(""), Number("0x10"), Number(true), Number(null), Number(undefined), Number({}));
out.push(String(12), String(null), String(undefined), String(true), String([1, [2, 3]]), String({}), Boolean(""), Boolean("0"), Boolean(0), Boolean({}));
var boxed = new Number(42);
var boxedString = new String("abc");
var boxedBool = new Boolean(false);
out.push(typeof boxed, boxed + 1, boxed.valueOf(), boxed == 42, boxed === 42, boxedString.length, boxedString[1], boxedString + "!", typeof boxedBool, !!boxedBool, boxedBool.valueOf(), Object.prototype.toString.call(boxed), Object.prototype.toString.call(boxedString), boxed instanceof Number, boxedString instanceof String);
out.push((255).toString(16), (255).toString(2), (-7.5).toString(2), (0.1).toString(3), (1e21).toString(), (3.14159).toFixed(2), (1.005).toFixed(1), (5).toFixed(0), (12).toString(), 7.5.valueOf());
out.push(Number.MAX_SAFE_INTEGER, Number.isInteger(5), Number.isInteger(5.5), Number.isInteger("5"), Number.isNaN(NaN), Number.isNaN("NaN"), Number.isFinite(1 / 0), Number.isSafeInteger(2 ** 53), Number.parseInt("8"), Number.EPSILON > 0);
out.push(true.toString(), (false).valueOf(), (1 < 2).toString());
out.push("hello".charAt(1), "hello".charCodeAt(1), "hello".charAt(9), "hello".at(-1), "hello".indexOf("l"), "hello".indexOf("l", 3), "hello".lastIndexOf("l"), "hello".indexOf("z"), "hello".includes("ell"), "hello".startsWith("he"), "hello".endsWith("lo"), "hello".endsWith("l", 4));
out.push("hello".slice(1, 3), "hello".slice(-3), "hello".substring(3, 1), "hello".substr(1, 2), "a,b,,c".split(","), "abc".split(""), "a b c".split(" ", 2), "no".split("x"), "hello".replace("l", "L"), "hello".replace("z", "Z"), "x".concat("y", 1), "  pad  ".trim() + "|" + "  pad  ".trimStart() + "|" + "  pad  ".trimEnd());
out.push("MiXeD".toUpperCase(), "MiXeD".toLowerCase(), "ab".repeat(3), "5".padStart(3, "0"), "5".padEnd(3), "abc".localeCompare("abd"), "b".localeCompare("a"), "same".localeCompare("same"), String.fromCharCode(72, 105), "abc".toString(), "abc".valueOf());
out.push("hello".replace("l", function (m, i) { return "[" + m + i + "]"; }));
var caught = [];
try { (5).toString(1); } catch (e) { caught.push(e.name); }
try { String.prototype.charAt.call(null); } catch (e) { caught.push(e.name); }
out.push(caught.join());
out.join("|");
