// `new.target` is an early error in code that is in no function: a
// script's, indirect eval code's, and the arrows, computed keys and class
// heritage written there. A function, method, accessor, constructor,
// field initializer or static block has its own, in its parameters and
// arrows too. Refused code never starts: `ran` stays 0. Direct eval code
// goes by where it is called; indirect eval code is in no function
// wherever it is called. Every source runs as global code through
// indirect eval, so node (which wraps a file in a function) agrees.
globalThis.ran = 0;
function early(source) {
  var out;
  ran = 0;
  try { (0, eval)("ran = 1; " + source); out = "ok"; } catch (e) { out = e.constructor.name; }
  console.log(out + " " + ran + "  " + source);
}
// Refused: in no function.
early("new.target");
early("new.target.x");
early("new new.target");
early("typeof new.target");
early("new.target?.x");
early("[new.target]");
early("({ a: new.target })");
early("({ [new.target]: 1 })");
early("({ ...new.target })");
early("`${new.target}`");
early("var a = new.target");
early("let { a = new.target } = {}");
early("if (new.target) {}");
early("for (;new.target;) {}");
early("x: { new.target; }");
early("try {} catch (e) { new.target; }");
early("switch (1) { case new.target: }");
early("() => new.target");
early("() => () => new.target");
early("(a = new.target) => a");
early("({ a = new.target }) => a");
early("async () => new.target");
early("async (a = new.target) => a");
early("({ a: () => new.target })");
early("(class { [new.target]() {} })");
early("(class { static [new.target]() {} })");
early("(class { get [new.target]() { return 1; } })");
early("(class { [new.target] = 1 })");
early("(class { static [new.target] = 1 })");
early("(class extends new.target {})");
early("(class { [(() => new.target)()]() {} })");
early("({ [new.target]() {} })");
early("({ get [new.target]() { return 1; } })");
early("eval('new.target')");
early("eval('() => new.target')");
early("(() => eval('new.target'))()");
early("eval('eval(\"new.target\")')");
early("(0, eval)('new.target')");
early("(class { [eval('new.target')]() {} })");
early("({ [eval('new.target')]: 1 })");
early("(class extends eval('new.target') {})");
// Accepted: a function, method, field or static block has its own.
early("(function () { return new.target; })");
early("(function (a = new.target) { return a; })");
early("(function () { return () => new.target; })");
early("(function* () { yield new.target; })");
early("(async function () { return new.target; })");
early("function f() { return new.target; }");
early("function g(a = () => new.target) { return a; }");
early("({ m() { return new.target; } })");
early("({ m(a = new.target) { return a; } })");
early("({ get x() { return new.target; } })");
early("({ set x(v = new.target) {} })");
early("({ f: function () { return new.target; } })");
early("({ *g() { yield new.target; } })");
early("(class { constructor() { new.target; } })");
early("(class { constructor(a = new.target) {} })");
early("(class { m() { return new.target; } })");
early("(class { static m(a = new.target) { return a; } })");
early("(class { get x() { return new.target; } })");
early("(class { x = new.target })");
early("(class { x = () => new.target })");
early("(class { #x = new.target })");
early("(class extends Object { x = new.target })");
early("(class extends Object { constructor() { super(); } x = new.target })");
early("(class { static x = new.target })");
early("(class { static x = () => new.target })");
early("(class { static { new.target; } })");
early("(class { static { (() => new.target)(); } })");
early("(class { x = class { [new.target]() {} } })");
early("(class { static x = { [new.target]: 1 } })");
early("(class { x = eval('new.target') })");
early("(class { static x = eval('new.target') })");
early("(class { static { eval('new.target'); } })");
early("(function () { return eval('new.target'); })()");
early("(function () { return (() => eval('new.target'))(); })()");
early("(function () { return eval('eval(\"new.target\")'); })()");
early("(function () { return eval('() => new.target')(); })()");
early("({ m() { return eval('new.target'); } }).m()");
early("new Function('return new.target')()");
early("new Function('return eval(\"new.target\")')()");
early("new Function('a = new.target', 'return a')()");
early("(function () { return 'new.target'; })()");
early("this === (function () { return new.target; })");
early("'new.target'");
early("/new.target/");
early("({ new: { target: 1 } }).new.target");
// Refused inside a function too: the eval code is global code.
early("(function () { return (0, eval)('new.target'); })()");
early("(function () { return (0, eval)('() => new.target'); })()");
early("new (class { x = (0, eval)('new.target') })()");
early("new (class { x = () => (0, eval)('new.target') })().x()");
early("(class { static x = (0, eval)('new.target') })");
