// An object literal assigned to a local is built in the local's register
// when nothing can see it half-built: the literal does not name the local
// and no try is open around it; otherwise it is built aside and moved.
function build(n) {
  var o = { a: 1 };
  var chain = null;
  for (var i = 0; i < n; i++) {
    o = { id: i, prev: o.id, tags: [i, i + 1] };
    chain = { o: o, next: chain };
  }
  var self = { x: 1 };
  self = { x: self.x + 1, y: self };
  var short = 5;
  short = { short };
  var viaEval = 3;
  viaEval = { v: eval("viaEval") };
  return [o.id, o.prev, o.tags.join(), chain.next.o.id, self.x, self.y.x, short.short, viaEval.v].join(" ");
}
console.log(build(5));

function thrower() { throw new Error("mid-literal"); }
function guarded() {
  var kept = { name: "old" };
  try {
    kept = { name: "new", bad: thrower() };
  } catch (e) {
    return kept.name + " " + e.message;
  }
  return "unreached";
}
console.log(guarded());
function escapes() {
  var kept = { name: "old" };
  kept = { name: "new", bad: thrower() };
  return kept.name;
}
try { escapes(); } catch (e) { console.log("escaped", e.message); }

function methods() {
  let counter = { n: 0 };
  counter = { n: 1, bump() { return ++this.n; }, get twice() { return this.n * 2; } };
  counter.bump();
  const fixed = { k: "const" };
  return counter.n + " " + counter.twice + " " + fixed.k;
}
console.log(methods());
function* gen() { var g = { step: 0 }; g = { step: (yield g.step) + 1 }; return g.step; }
var it = gen();
console.log(it.next().value, it.next(41).value);
