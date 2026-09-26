// A string joined with an int32 on either side: digits and signs, wide
// strings, and buffers extended in place while earlier strings over them
// keep their own prefixes.
var out = [];
var w = "中";
out.push("k" + 0, "k" + -1, "k" + 2147483647, "k" + -2147483648, 5 + "x", -12 + "x", "" + 7, 7 + "", w + 12, 34 + w, "a" + 1.5, 2.5 + "b");
var s = "p"; for (var i = 0; i < 5; i++) s = s + i; out.push(s);
var t = "q"; for (var j = 0; j < 3; j++) { var u = t + j; out.push(u); }
var base = "z"; var x1 = base + 1; var x2 = base + 2; out.push(x1, x2, base);
var grow = "g"; var keep = []; for (var k = 0; k < 4; k++) { grow = grow + k; keep.push(grow); } out.push(keep.join(","));
console.log(out.join("|"));
