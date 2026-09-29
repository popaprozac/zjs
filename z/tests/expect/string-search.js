// indexOf and its relatives try a start only when the needle's first and
// last bytes both match there.
var s = "item0|item1|item12|item499|xx";
console.log(s.indexOf("item499"), s.indexOf("item4"), s.indexOf("x"), s.indexOf("xx"), s.indexOf("xxx"));
console.log(s.indexOf("item1"), s.indexOf("|item12|"), s.indexOf("item499|xx"), s.indexOf("a"));
console.log("abab".indexOf("ab", 1), "aaa".indexOf("aa", 1), "ab".indexOf("b", 1), "ab".indexOf("ab", 1));
console.log(s.lastIndexOf("item"), s.includes("m12|"), s.includes("m12x"), s.split("item").length);
console.log("aXbXa".indexOf("aXa"), "abcabd".indexOf("abd"), "abcab".indexOf("abcab"), "ab".indexOf("abc"));
console.log("é-ü-é".indexOf("ü-é"), "a✓b✓c".indexOf("✓c"), "x".repeat(300).indexOf("xy"), ("x".repeat(300) + "y").indexOf("xy"));
