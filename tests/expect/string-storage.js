// Small strings kept across collections that compact their storage:
// narrow and wide, substrings, concatenation prefixes sharing bytes, Map
// keys, and large strings beside them.
var keep = [], m = new Map(), prefixes = [];
var s = "";
for (var i = 0; i < 3000; i++) {
  var w = (i % 3 === 0) ? "中" + i : "k" + i;
  keep.push(w);
  if (i % 7 === 0) keep.push(w.slice(1) + "|" + w.substring(0, 2));
  m.set(w, i);
  if (i < 300) { s += String.fromCharCode(97 + (i % 26)); prefixes.push(s); }
  if (i % 50 === 0) { var junk = []; for (var j = 0; j < 2000; j++) junk.push("x" + j + "y" + (j * 3)); if (typeof gc === "function") gc(); }
}
var h = 0;
for (var k = 0; k < keep.length; k++) { var t = keep[k]; for (var c = 0; c < t.length; c++) h = (h * 31 + t.charCodeAt(c)) | 0; }
var p = 0; for (var q = 0; q < prefixes.length; q++) p = (p + prefixes[q].length + prefixes[q].charCodeAt(prefixes[q].length - 1)) | 0;
var g = 0; for (var n = 0; n < 3000; n++) g += m.get((n % 3 === 0) ? "中" + n : "k" + n);
var big = ""; for (var b = 0; b < 400; b++) big += "abc"; var cut = big.slice(10, 200) + big.slice(1000);
console.log(keep.length, h, p, g, m.size, big.length, cut.length, cut.charCodeAt(5), JSON.stringify(keep.slice(0, 8)), prefixes[299].slice(-5));
