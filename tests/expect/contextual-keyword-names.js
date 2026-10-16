// Words that are keywords only in some places are identifiers elsewhere,
// shorthand properties included; `let` is reserved in strict code.
var from = 1, of = 2, async = 3, as = 4, yield = 6, await = 7;
var let = 5;
var o = { from, of, async, as, let, yield, await };
console.log(JSON.stringify(o));
var { from: f, async: a } = o;
console.log(f, a);
function g(from, of) { return { from, of }; }
console.log(JSON.stringify(g(8, 9)));

function rejects(source) {
  try { Function(source); return "accepted"; } catch (e) { return e.name; }
}
console.log(rejects("'use strict'; var o = { let };"));
console.log(rejects("'use strict'; var let = 1;"));
console.log(rejects("function* g() { var o = { yield }; }"));
console.log(rejects("async function g() { var o = { await }; }"));
console.log(rejects("var o = { let }; return o.let;"));
