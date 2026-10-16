// split with a string separator: one pass finds every separator, and the
// pieces go into an array made at their count.
var cases = [
  ["a,b,c", ","], [",a,,b,", ","], ["", ","], ["abc", ","], ["aaaa", "aa"], ["aaa", "aa"],
  ["one--two----three", "--"], ["x", "x"], ["xx", "x"], ["é,ü,✓", ","], ["a✓b✓c", "✓"],
  ["long " + "word ".repeat(100), " "],
];
var out = [];
for (var i = 0; i < cases.length; i++) {
  var parts = cases[i][0].split(cases[i][1]);
  out.push(parts.length + " " + JSON.stringify(parts.length > 6 ? parts.slice(0, 3).concat(parts.slice(-2)) : parts));
}
out.push(JSON.stringify("a,b,c,d".split(",", 2)), JSON.stringify("a,b".split(",", 0)), JSON.stringify("a,b".split(",", 10)));
out.push(JSON.stringify("abc".split("")), JSON.stringify("abc".split(undefined)), JSON.stringify("a1b1c".split(1)));
var big = "";
for (var j = 0; j < 500; j++) big += "item" + j + ",";
var pieces = big.split(",");
out.push(pieces.length + " " + pieces[0] + " " + pieces[499] + " [" + pieces[500] + "]");
console.log(out.join("\n"));
