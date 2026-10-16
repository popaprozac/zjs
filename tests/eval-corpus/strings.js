var log = [];
var ws = "       　﻿ \t\n\v\f\r";
log.push((ws + "abc" + ws).trim() === "abc", (ws + "abc" + ws).trimStart() === "abc" + ws, (ws + "abc" + ws).trimEnd() === ws + "abc", "  x ".trim().length);
log.push("abc".toLocaleUpperCase(), "ABC".toLocaleLowerCase(), "aXb".replaceAll("X", "-"), "a.b.c".replaceAll(".", "!"), "abc".replaceAll("", "_"), "xax".replaceAll("a", function (m, i, s) { return m + i + s.length; }));
log.push("abc".replace("b", "[$&]"), "abc".replace("b", "$`|$'"), "abc".replace("b", "$$"), "abc".replace("b", "$1"), "aXbXc".replaceAll("X", "$&$&"));
log.push(String.raw`a\n${1 + 1}b`, String.raw({ raw: ["x", "y", "z"] }, 1, 2, 3), String.raw({ raw: "ab" }, 9), String.raw.length);
log.push(String.fromCodePoint(97, 98), String.fromCodePoint(), String.fromCodePoint.length);
var errors = [];
try { String.fromCodePoint(-1); } catch (e) { errors.push(e.name); }
try { String.fromCodePoint(0x110000); } catch (e) { errors.push(e.name); }
try { String.fromCodePoint(1.5); } catch (e) { errors.push(e.name); }
log.push(errors.join(), "a".replaceAll(null, "x"), "anullb".replaceAll(null, "-"));
var str = "The future is cool!";
log.push(str.includes("The future", -1), str.includes("The future", true), str.includes("cool", NaN), str.startsWith("!", str.length), str.startsWith("!", 100), str.startsWith("The", -5), str.endsWith("cool", 18), str.endsWith("cool", 100), str.endsWith("!", -1), str.includes("", 100));
log.push("a-b-c".split("-", 2).join(), "abc".split("").length, "abc".split().length);
log.join("|");
