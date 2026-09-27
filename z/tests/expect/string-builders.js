// Strings searched where their bytes are (indexOf, includes, split),
// joined through a builder that stays in bytes until a unit needs two,
// and concatenated onto a buffer from the arena directly. The edges of
// those paths, each against node.
var sections = [];
sections.push((function () {
var s = "abcabcabd" + "x".repeat(300) + "needle" + "y".repeat(10);
var out = [s.indexOf("abd"), s.indexOf("abc", 1), s.indexOf("needle"), s.indexOf("needle", 400), s.indexOf(""), s.indexOf("", 999), s.indexOf("zz"),
  "short".indexOf("longer than"), s.includes("needle"), s.includes("needlez"), s.includes("abc", 7), "é-é".indexOf("-é"), "中文".indexOf("文"), "aaa".indexOf("aa", 2), "aaa".indexOf("a", -5), s.indexOf("y", s.length)];
return out.join(",");
})());
sections.push((function () {
var out = ["a,b,,c".split(","), "a,b,c".split(",", 2), ",a,".split(","), "abc".split(""), "a--b--".split("--"), "aaa".split("aa"), "".split(","), "x".split("xyz"), "é,中,e".split(","), "a中b中".split("中"), ("item1," + "item2,").split(",")];
return JSON.stringify(out);
})());
sections.push((function () {
var out = [[1, 2, 3].join(), [1, "a", null, undefined, true].join("-"), ["é", "中", "x"].join("|"), [].join(), [[1, 2], [3]].join(";"), ["a", "b"].join("中"),
  Array(3).join("ab"), [1.5, -0, 1e21, NaN].join(" "), [{ toString: function () { return "T"; } }, 2].join("+"), ["x".repeat(300), "y"].join("é").length];
var sep = { toString: function () { var junk = []; for (var i = 0; i < 100; i++) junk.push({}); return "<>"; } };
out.push(["p", "q", "r"].join(sep));
return out.join("\n");
})());
var built = ""; for (var i = 0; i < 400; i++) built += "p" + i + (i % 50 === 0 ? "é" : ",");
sections.push(built.length + ":" + built.slice(-12) + ":" + built.indexOf("p399"));
console.log(sections.join("\n"));
