// join: an array of strings, numbers, booleans, undefined, and null is
// gathered in one pass; anything else, a hole, or a wide string takes
// the general path from the first element.
console.log([1, -2, 3.5, "a", true, false, null, undefined, -0, NaN, 1e21, 2147483647, -2147483648].join());
console.log([1, 2, 3].join("--"), [].join(), [, 1].join(), [1, , 2].join("|"));
console.log(["ሴ", "b"].join(), ["a", "b"].join("é"), ["a", "b"].join("一"));

// An object element converts through its own toString, in order.
var order = [];
var o = { toString() { order.push("o"); return "O"; } };
console.log([1, o, 2].join("+"), order.join());

// A length past the elements, nested arrays, and odd separators.
var a = [1, 2];
a.length = 4;
console.log(a.join("."));
console.log([[1, 2], [3]].join(";"), [1, 2].join(undefined), [1, 2].join(null));

// A hole reads through the prototype.
Array.prototype[1] = "P";
console.log([0, , 2].join());
delete Array.prototype[1];

// Long results, and many joins with allocation between them.
var big = [];
for (var i = 0; i < 1000; i++) big.push(i);
console.log(big.join("").length, big.join(", ").length);
var words = [];
for (var j = 0; j < 5000; j++) words.push(["w" + j, j, j % 2 === 0].join(":"));
console.log(words.length, words[4999], words.join("").length);

// toLocaleString calls each element's own toLocaleString.
Boolean.prototype.toLocaleString = function () { "use strict"; return "b:" + typeof this; };
Number.prototype.toLocaleString = function () { return "n"; };
console.log([true, false, 1].toLocaleString(), [null, undefined, "s"].toLocaleString());
