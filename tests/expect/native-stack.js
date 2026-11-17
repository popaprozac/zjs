// Data and source text nested deeper than the native stack has room for
// throw a RangeError that a program can catch, and the engine goes on
// working afterwards. None of these opens a JavaScript frame a level:
// the recursion is a builtin's over nested arrays and objects, or the
// parser's and the compiler's over nested source. (tests/expect/call-depth.js
// has the recursions that go through a function.)
//
// Everything here is built to a fixed depth: an engine with no limit
// finishes or crashes at once, and fails the case. Source text is nested
// less deep than data, since a parser looks ahead from every parenthesis
// to the one that closes it.
var DEPTH = 100000;
var SOURCE_DEPTH = 20000;

function report(label, run) {
  try {
    console.log(label, "returned", run());
  } catch (e) {
    console.log(label, e instanceof RangeError, e.name + ": " + e.message);
  }
}

// --- Builtins over nested data.

var nested = [1];
for (var i = 0; i < DEPTH; i++) nested = [nested];
var chain = { end: true };
for (var j = 0; j < DEPTH; j++) chain = { next: chain };

report("String of nested arrays", function () { return String(nested).length; });
report("join", function () { return nested.join("-").length; });
report("toString", function () { return nested.toString().length; });
report("toLocaleString", function () { return nested.toLocaleString().length; });
report("concatenation", function () { return ("" + nested).length; });
report("template", function () { return `${nested}`.length; });
report("flat", function () { return nested.flat(Infinity).length; });
// (JSON.stringify without a replacer is left out: V8 writes that form
// without recursing and reaches the end.)
function same(key, value) { return value; }
report("JSON.stringify of nested arrays", function () { return JSON.stringify(nested, same).length; });
report("JSON.stringify of nested objects", function () { return JSON.stringify(chain, same).length; });

// Below the limit they answer.
var shallow = [1];
for (var k = 0; k < 500; k++) shallow = [shallow];
console.log("500 deep:", String(shallow), shallow.flat(Infinity).length, JSON.stringify(shallow).length);
console.log("JSON.parse 2000 deep:", JSON.parse("[".repeat(2000) + "]".repeat(2000)).length);

// --- Source text: the parser and the compiler.

function wrapped(open, middle, close) { return open.repeat(SOURCE_DEPTH) + middle + close.repeat(SOURCE_DEPTH); }

report("parentheses", function () { return eval(wrapped("(", "1", ")")); });
report("array literals", function () { return eval(wrapped("[", "", "]")).length; });
report("object literals", function () { return eval("var o=" + wrapped("{a:", "1", "}")); });
report("calls", function () { return eval("function id(x){return x}" + wrapped("id(", "1", ")")); });
report("unary operators", function () { return eval("!".repeat(SOURCE_DEPTH) + "1"); });
report("assignments", function () { return eval("var q;" + "q=".repeat(SOURCE_DEPTH) + "1"); });
report("blocks", function () { return eval(wrapped("{", "", "}")); });
report("if statements", function () { return eval("if(1)".repeat(SOURCE_DEPTH) + ";"); });
report("array patterns", function () { return eval("var " + wrapped("[", "p", "]") + "=[]"); });
report("template literals", function () { return eval("`${".repeat(DEPTH) + "1" + "}`".repeat(DEPTH)); });
report("the Function constructor", function () { return new Function("return " + "!".repeat(SOURCE_DEPTH) + "1")(); });
report("indirect eval", function () { return (0, eval)(wrapped("{", "", "}")); });

// Below the limit it compiles: nested, and in a chain the parser builds
// without nesting.
console.log("200 parentheses:", eval("(".repeat(200) + "7" + ")".repeat(200)));
console.log("2000 terms:", eval("1" + "+1".repeat(2000)));

// --- The error is an ordinary one.

// Caught far down a recursion of the program's own, with little stack
// left, and the program goes on from there.
function inside(n) {
  if (n > 0) return inside(n - 1);
  try { return String(nested).length; } catch (e) { return e instanceof RangeError; }
}
console.log("caught 2000 calls down:", inside(2000));

// A finally block runs on the way out.
var unwound = 0;
try {
  try { JSON.stringify(nested, same); } finally { unwound = unwound + 1; }
} catch (e) { unwound = unwound + 1; }
console.log("finally and catch ran:", unwound);

// The same again: nothing is left behind by the first time.
report("String of nested arrays, again", function () { return String(nested).length; });
report("blocks, again", function () { return eval(wrapped("{", "", "}")); });

// An array that holds itself is not deep: its own join is empty.
var loop = [1, 2]; loop.push(loop);
console.log("self-holding:", String(loop));

// And ordinary work after all of it.
console.log("after:", [1, [2, [3, [4]]]].flat(Infinity).join(), JSON.stringify({ a: [1, { b: 2 }] }), eval("(1 + 2) * 3"));
