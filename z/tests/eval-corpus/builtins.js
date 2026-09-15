var log = [];
log.push(eval("1 + 2"), eval("var evalVar = 7; evalVar * 2"), evalVar, eval(42), typeof eval);
log.push(parseInt("42px"), parseInt("  -0x1A"), parseInt("101", 2), parseInt("z", 36), parseInt("abc"), parseFloat("3.25e1xyz"), parseFloat("-.5"), parseFloat("Infinity!"), parseFloat("x"));
log.push(isNaN("abc"), isNaN("12"), isFinite("1e3"), isFinite(1 / 0));
function greet(greeting, punctuation) { return greeting + " " + this.name + punctuation; }
var person = { name: "Zed" };
log.push(greet.call(person, "hi", "!"), greet.apply(person, ["yo", "?"]), greet.apply(person), greet.length);
var arr = [3, 1, 2];
log.push(arr.push(9, 8), arr.pop(), arr.join("-"), arr.indexOf(1), arr.indexOf(7), arr.slice(1).join(), arr.slice(-2, 3).join(), arr.map(function (v, i) { return v * i; }).join(), arr.filter(function (v) { return v > 1; }).length, arr.some(function (v) { return v > 8; }), arr.every(function (v) { return v > 0; }), Array.isArray(arr), Array.isArray({}), new Array(3).length, Array(1, 2).join());
var seen = "";
arr.forEach(function (v, i, a) { seen += v + ":" + i + ":" + a.length + ";"; });
log.push(seen);
log.push(Object.prototype.toString.call(arr), Object.prototype.toString.call(null), "" + {}, "" + { toString: function () { return "custom"; } }, ({ valueOf: function () { return 5; } }) + 1, ({}).hasOwnProperty("x"), person.hasOwnProperty("name"), Object.prototype.isPrototypeOf(person));
var err = new TypeError("bad");
log.push("" + err, err.toString(), Error.prototype.toString.call({ name: "N", message: "" }), new Error("m") + "");
log.push(typeof globalThis, globalThis.person === person, this === globalThis, (function () { return this === globalThis; })());
var caught = "";
try { eval("var x = ;"); } catch (e) { caught = e.name; }
log.push(caught);
log.join("|");
