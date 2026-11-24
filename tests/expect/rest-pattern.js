// A rest parameter that is a pattern, `(...[a, b])` or `(...{ length })`:
// the arguments past the plain parameters are collected into an array,
// which the pattern then reads as any array (through the array iterator
// for `[...]`), in the parameters' order and scope. A rest parameter, a
// name or a pattern, does not count toward the function's length. Every
// source runs as global code through indirect eval and prints its value
// or its error's kind.
globalThis.log = [];
globalThis.note = function (x) { log.push(x); return x; };
const sources = [
  // Values.
  "((...[a, b]) => a + b)(1, 2)",
  "(function (...[a, b]) { return a + b; })(1, 2)",
  "(function (...{ length }) { return length; })(1, 2, 3)",
  "((x, ...[a, b = 5]) => [x, a, b].join())(1, 2)",
  "((...[a, ...b]) => b.join())(1, 2, 3)",
  "((...[[a], { b }]) => a + b)([1], { b: 2 })",
  "((...[]) => 7)(1, 2)",
  "((...{}) => 8)(1, 2)",
  "(function (...{ 0: a, ...others }) { return a + ':' + Object.keys(others).join(); })(1, 2, 3)",
  "(function (...[a]) { return arguments.length; })(1, 2)",
  "(function (...[a]) { a = 2; return arguments[0]; })(1)",
  "(function (...[a, b]) {}).length",
  "((a, ...[b]) => 0).length",
  "(function (a, b = 1, ...[c]) {}).length",
  "(function (a, ...b) {}).length",
  "((...a) => 0).length",
  "(class { m(a, b, ...c) {} }).prototype.m.length",
  "({ m(...[a]) { return a; } }).m(7)",
  "(class { m(...[a, b]) { return a * b; } }).prototype.m(3, 4)",
  "(class { static m(...{ length }) { return length; } }).m(3, 4)",
  "new (class { constructor(...[a]) { this.a = a; } })(5).a",
  "new (class extends Object { constructor(...[a]) { super(); this.a = a; } })(6).a",
  "new (class { x = 1; constructor(...[a]) { this.a = a + this.x; } })(5).a",
  "(function* (...[a, b]) { yield a; yield b; })(1, 2).next().value",
  "[...(function* (...[a, b]) { yield a; yield b; })(1, 2)].join()",
  "new Function('...[a, b]', 'return a + b')(1, 2)",
  "new Function('x', '...{ length }', 'return x + length')(1, 2, 3)",
  // Scope: closures, defaults, eval.
  "((...[a]) => () => a)(4)()",
  "((x, ...[a = x]) => a)(9)",
  "((...[a, b = () => a]) => b())(3)",
  "((...[a, b = a + 1]) => b)(3)",
  "((a = 1, ...r) => () => a + ':' + r.join())(undefined, 6, 7)()",
  "((a = 1, ...[b, c]) => () => a + b + c)(undefined, 6, 7)()",
  "((...[a]) => eval('a'))(5)",
  "(function (...[a]) { return eval('a + arguments.length'); })(5, 6)",
  "(function (...[a]) { var a; return a; })(5)",
  "(function (...[a]) { function a() {} return typeof a; })(5)",
  "((...[a]) => { let b = a; return () => b; })(8)()",
  "(function (...[a, b]) { return [a, b].map(v => v * this.k).join(); }).call({ k: 2 }, 1, 2)",
  "((...[a = this === globalThis]) => a)()",
  // Order and errors when called.
  "((...[a = b, b]) => a)()",
  "((...[a = a]) => a)()",
  "(function (...[{ x }]) {})()",
  "(function (...[{ x }]) { return x; })({ x: 3 })",
  "log = [], ((a = note('a'), ...[b = note('b'), c = note('c')]) => 0)(), log.join()",
  "log = [], (function* (...[a = note('made')]) { note('ran'); })(), log.join()",
  "log = [], (function (a = note(1), ...{ length: n = note(2), [note(3)]: m }) {})(), log.join()",
  // Syntax errors.
  "(...[a] = []) => 0",
  "(...[a],) => 0",
  "(...[a], b) => 0",
  "(...[a, a]) => 0",
  "(a, ...[a]) => 0",
  "(function (a, ...[a]) {})",
  "(function (...[a]) { 'use strict'; })",
  "(...[a]) => { 'use strict'; }",
  "'use strict'; (...[eval]) => 0",
  "'use strict'; (function (...[arguments]) {})",
  "(async function (...[a = await 1]) {})",
  "(...[a.b]) => 0",
  "(...[(a)]) => 0",
  "(......[a]) => 0",
  "(function (...[a]) { let a; })",
  "((...[a]) => { let a; })",
  // Accepted in sloppy code.
  "typeof ((...[eval]) => 0)",
  "typeof (function (...[yield]) {})",
  "typeof (function (...[await]) {})",
  "typeof ((...[a]) => { var a; })",
  "typeof (async (...[a]) => a)",
  "typeof (async function* (...{ length }) {})",
];
for (const source of sources) {
  let result;
  try { result = String((0, eval)(source)); } catch (error) { result = error.constructor.name; }
  console.log(source + " => " + result);
}
// The pattern reads the rest array through the array iterator.
{
  const saved = Array.prototype[Symbol.iterator];
  let calls = 0;
  Array.prototype[Symbol.iterator] = function () { calls++; return saved.call(this); };
  let a = 0, b = 0;
  try { a = ((...[x]) => x)(1); b = ((...{ length }) => length)(1, 2); } catch (error) { a = error.constructor.name; }
  Array.prototype[Symbol.iterator] = saved;
  console.log("iterator calls " + calls + " " + a + " " + b);
}
// A rest array is a fresh array each call.
{
  const f = (...[a, ...more]) => more;
  const one = f(1, 2), two = f(1, 2);
  console.log("fresh " + (one !== two) + " " + Array.isArray(one) + " " + one.length);
}
(async (...[a, b]) => a + b)(1, 2).then(v => console.log("async arrow " + v));
(async function (...{ length }) { return length; })(1, 2, 3).then(v => console.log("async function " + v));
