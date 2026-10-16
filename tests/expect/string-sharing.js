// Strings built by concatenation share a buffer, each seeing its own
// prefix: every one keeps its own content, before and after a collection.
var out = [];
var s = "a";
var snapshots = [];
for (var i = 0; i < 6; i++) { s += i; snapshots.push(s); }
out.push(snapshots.join("|"));
var base = "x" + "y";          // a fresh appendable buffer
var one = base + "1";          // extends it in place
var two = base + "2";          // base is no longer the newest: copies
out.push([base, one, two, one + two, base.length, one.length].join(" "));
var w = "ā" + "Ă";   // wide
var w2 = w + "ă";
out.push([w, w2, w2.length, w2.charCodeAt(2)].join(" "));
var mixed = "ab" + "ā";
out.push(mixed + " " + mixed.length);
var same = s + s;              // the same string on both sides
out.push(same.length + " " + (same === s + s));
var keys = {};
keys[one] = 1; keys[two] = 2; keys[base + "1"] = 3;
out.push(JSON.stringify(keys));
var big = "";
for (var j = 0; j < 20000; j++) big += "k";
out.push(big.length + " " + big.slice(19990) + " " + (big === "k".repeat(20000)));
var parts = [];
for (var k = 0; k < 5; k++) { var t = "p" + k; t += "-"; parts.push(t); }
out.push(parts.join(","));
if (typeof gc === "function") gc();
out.push(snapshots[2] + " " + one + " " + two + " " + w2);
console.log(out.join("\n"));
