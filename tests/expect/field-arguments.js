// `arguments` in direct eval code called in a class field's initializer is
// a SyntaxError (PerformEval: inClassFieldInitializer and ContainsArguments).
function show(label, run) {
  let result;
  try { result = String(run()); } catch (error) { result = "throws " + error.constructor.name; }
  console.log(label + ": " + result);
}
var ran = 0;

// Refused: the name is read in the initializer's own code or through arrows.
show("field", () => { class C { x = eval("ran++; arguments"); } return new C().x; });
show("field typeof", () => { class C { x = eval("typeof arguments"); } return new C().x; });
show("field arrow in eval", () => { class C { x = eval("ran++; () => arguments"); } return new C().x; });
show("field eval in arrow", () => { class C { x = () => eval("ran++; arguments"); } return new C().x(); });
show("field nested arrows", () => { class C { x = () => () => eval("() => () => arguments"); } return new C().x()(); });
show("field in block", () => { class C { x = eval("{ if (true) { arguments; } }"); } return new C().x; });
show("field nested eval", () => { class C { x = eval("eval('ran++; arguments')"); } return new C().x; });
show("field eval of eval in arrow", () => { class C { x = eval("() => eval('arguments')"); } return new C().x(); });
show("field method key", () => { class C { x = eval("({ [arguments]() {} })"); } return new C().x; });
show("field accessor key", () => { class C { x = eval("({ get [arguments]() { return 1; } })"); } return new C().x; });
show("field class method key", () => { class C { x = eval("(class { [arguments]() {} })"); } return new C().x; });
show("field template", () => { class C { x = eval("`${arguments}`"); } return new C().x; });
show("field call argument", () => { class C { x = eval("String(arguments)"); } return new C().x; });
show("field default parameter of arrow", () => { class C { x = eval("(a = arguments) => a"); } return new C().x; });
show("private field", () => { class C { #x = eval("ran++; arguments"); get x() { return this.#x; } } return new C().x; });
show("private field arrow", () => { class C { #x = () => eval("arguments"); get x() { return this.#x(); } } return new C().x; });
show("static field", () => { class C { static x = eval("ran++; arguments"); } return C.x; });
show("static field arrow", () => { class C { static x = () => eval("arguments"); } return C.x(); });
show("static private field", () => { class C { static #x = eval("arguments"); static get x() { return C.#x; } } return C.x; });
show("computed-key field", () => { class C { ["k"] = eval("arguments"); } return new C().k; });
show("derived field", () => { class B {} class C extends B { x = eval("ran++; arguments"); } return new C().x; });
show("derived field, written constructor", () => { class B {} class C extends B { x = eval("arguments"); constructor() { super(); } } return new C().x; });
show("derived field, arrow super", () => { class B {} class C extends B { x = eval("arguments"); constructor() { (() => super())(); } } return new C().x; });
show("field in function with arguments", () => { function f() { return class { x = eval("arguments"); }; } return new (f(1, 2))().x; });
show("class expression field", () => { const C = class { x = eval("arguments"); }; return new C().x; });
show("escaped name", () => { class C { x = eval("argument\\u0073"); } return new C().x; });
console.log("ran: " + ran);

// Allowed: a function or method in between has its own arguments.
show("function in eval", () => { class C { x = eval("(function () { return arguments.length; })(1, 2, 3)"); } return new C().x; });
show("eval in function", () => { class C { x = function () { return eval("arguments.length"); }; } return new C().x(1, 2); });
show("method in eval", () => { class C { x = eval("({ m() { return arguments.length; } }).m(1)"); } return new C().x; });
show("eval in method", () => { class C { x = ({ m() { return eval("arguments.length"); } }).m(1, 2, 3, 4); } return new C().x; });
show("arrow in function in eval", () => { class C { x = eval("(function () { return (() => arguments.length)(); })(7, 8)"); } return new C().x; });
show("generator in eval", () => { class C { x = eval("(function* () { yield arguments.length; })(1).next().value"); } return new C().x; });
show("class method in eval", () => { class C { x = eval("new (class { m() { return arguments.length; } })().m(1, 2)"); } return new C().x; });
show("property named arguments", () => { class C { x = eval("({ arguments: 5 }).arguments"); } return new C().x; });
show("member named arguments", () => { class C { x = eval("({ a: 1 }).arguments"); } return new C().x; });
show("string holding the name", () => { class C { x = eval("'arguments'"); } return new C().x; });
show("indirect eval", () => { class C { x = (0, eval)("typeof arguments"); } return new C().x; });
show("eval of no name", () => { class C { x = eval("1 + 1"); } return new C().x; });

// Allowed: not a field's initializer.
show("method", () => { class C { m() { return eval("arguments.length"); } } return new C().m(1, 2); });
show("constructor", () => { class C { constructor() { this.n = eval("arguments.length"); } } return new C(1, 2, 3).n; });
show("constructor arrow", () => { class C { constructor() { this.n = (() => eval("arguments.length"))(); } } return new C(1).n; });
show("constructor beside a field", () => { class C { y = 1; constructor() { this.n = eval("arguments.length"); } } return new C(1, 2).n; });
show("computed key", () => { function f() { return class { [eval("arguments.length")] = 1; }; } return Object.keys(new (f(1, 2))())[0]; });
show("function", () => { function f() { return eval("arguments.length"); } return f(1, 2, 3); });
show("getter", () => { class C { get x() { return eval("arguments.length"); } } return new C().x; });
show("static method", () => { class C { static m() { return eval("arguments.length"); } } return C.m(1); });

// The refusal comes before any of the code runs, each time it is called.
show("refused twice", () => {
  class C { x = eval("ran++; arguments"); }
  let count = 0;
  for (let i = 0; i < 3; i++) { try { new C(); } catch (error) { if (error instanceof SyntaxError) count++; } }
  return count;
});
show("a later field does not run", () => {
  let later = 0;
  class C { x = eval("arguments"); y = later++; }
  try { new C(); } catch (error) {}
  return later;
});
console.log("ran: " + ran);

// The same check on the class's own text: `arguments` in a field's
// initializer or a static block, wherever it is read as a name.
const sources = [
  // Refused.
  "class C { x = arguments }",
  "class C { x = a => arguments }",
  "class C { x = (a = arguments) => a }",
  "class C { x = ({ a = arguments }) => a }",
  "class C { x = ([a = arguments]) => a }",
  "class C { x = ({ [arguments]: a }) => a }",
  "class C { x = async (a = arguments) => a }",
  "class C { x = (a, b = () => arguments) => a }",
  "class C { x = (a, b = (c = arguments) => c) => a }",
  "class C { x = { [arguments]() {} } }",
  "class C { x = { get [arguments]() { return 1; } } }",
  "class C { x = class { [arguments]() {} } }",
  "class C { x = class { static [arguments]() {} } }",
  "class C { x = class { [arguments] = 1 } }",
  "class C { x = { arguments } }",
  "class C { x = argument\\u0073 }",
  "class C { x = () => argument\\u0073 }",
  "class C { static x = (a = arguments) => a }",
  "class C { static x = argument\\u0073 }",
  "class C { #x = (a = arguments) => a }",
  "class C { static { arguments; } }",
  "class C { static { ((a = arguments) => a)(); } }",
  "class C { static { (({ a = arguments }) => a)({}); } }",
  "class C { static { class D { [arguments]() {} } } }",
  "class C { static { ({ [arguments]() {} }); } }",
  // Accepted: a function or method has its own, and a name that is not read.
  "class C { x = function () { return arguments; } }",
  "class C { x = function (a = arguments) { return a; } }",
  "class C { x = { m() { return arguments; } } }",
  "class C { x = { m(a = arguments) { return a; } } }",
  "class C { x = class { m() { return arguments; } } }",
  "class C { x = class { constructor() { arguments; } } }",
  "class C { x = { arguments: 1 } }",
  "class C { x = this.arguments }",
  "class C { x = 'arguments' }",
  "class C { arguments = 1 }",
  "class C { x = { arguments() {} } }",
  "class C { x = () => function () { return arguments; } }",
  "class C { static { function f() { return arguments; } } }",
  "class C { static { (function () { return arguments; })(); } }",
  "class C { static { ({ m() { return arguments; } }); } }",
  "class C { m() { return arguments; } }",
  "class C { m(a = arguments) { return () => arguments; } }",
  "class C { constructor() { arguments; } x = 1 }",
  "function f() { return class { [arguments.length] = 1 }; }",
];
for (const source of sources) {
  let result = "accepted";
  try { (0, eval)(source); } catch (error) { result = error.constructor.name; }
  console.log(source + " => " + result);
}
