// Functions past the compiler's fixed widths, built as source and compiled
// with Function: more locals than registers, more captured bindings than
// a byte names, jumps longer than 16 bits, more arguments than a register
// window, and long chains, sequences, and templates whose temporaries
// must be freed as they go.
function repeat(count, piece) {
  var parts = [];
  for (var i = 0; i < count; i++) parts.push(piece(i));
  return parts;
}

var locals = Function(repeat(300, function (i) { return "var v" + i + " = " + i + ";"; }).join("\n") +
  "\nreturn v0 + v150 + v299;");
console.log("locals", locals());

var lets = Function(repeat(300, function (i) { return "let l" + i + " = " + i + ";"; }).join("\n") +
  "\nconst read = () => l0 + l299; return read() + l150;");
console.log("lets", lets());

var captured = Function(repeat(300, function (i) { return "let c" + i + " = " + i + ";"; }).join("\n") +
  "\nreturn function () { return " + repeat(300, function (i) { return "c" + i; }).join(" + ") + "; };");
console.log("captured", captured()());

var longLoop = Function("var t = 0;\nfor (var i = 0; i < 2; i++) {\n" +
  repeat(20000, function (i) { return "  t = (t + " + i + ") | 0;"; }).join("\n") + "\n}\nreturn t;");
console.log("long loop", longLoop());

var args = repeat(300, function (i) { return String(i); }).join(", ");
var count = Function("function f() { return arguments.length; }\nfunction P() { this.n = arguments.length; }\n" +
  "var o = { m: function () { return arguments.length + (this === o ? 1000 : 0); } };\n" +
  "return [f(" + args + "), new P(" + args + ").n, o.m(" + args + ")];");
console.log("arguments", count().join(" "));

var chain = Function("return 1" + repeat(2000, function () { return " + 1"; }).join("") + ";");
console.log("chain", chain());

var sequence = Function("var o = {};\n" + repeat(600, function (i) { return "o.k" + i + " = { v: [" + i + "] }"; }).join(", ") +
  ";\nreturn Object.keys(o).length + o.k599.v[0];");
console.log("sequence", sequence());

var template = Function("return `" + repeat(1000, function (i) { return "${" + i + "}-"; }).join("") + "`.length;");
console.log("template", template());

var strings = Function("var s = 'a'" + repeat(500, function (i) { return " + 's" + i + "'"; }).join("") + ";\nreturn s.length;");
console.log("strings", strings());
