// The frame limit holds its place: overflow after overflow, a recursion
// gets exactly as deep as the first time. The frame that passes the limit
// takes a slot the engine gives back once it is gone; kept, each overflow
// would go one frame deeper than the last. Counted down from a bound,
// like every recursion in the tests, so an engine with no limit reaches
// the bottom and fails here without using the machine's memory up.
var depth = 0, deepest = 0;
function down(n) {
  depth = depth + 1;
  if (depth > deepest) deepest = depth;
  try { return n === 0 ? 0 : down(n - 1) + 1; } finally { depth = depth - 1; }
}
function overflow() { deepest = 0; try { down(100000); return -1; } catch (e) { return deepest; } }
var first = overflow(), same = 0;
for (var i = 0; i < 300; i++) if (overflow() === first) same = same + 1;

// The same from a catch a few frames under the limit, which tries again
// at once.
var most = 0, caught = 0;
function climb(n) { if (n > most) most = n; return climb(n + 1); }
function retry(n) {
  if (n < first - 10) return retry(n + 1);
  for (var k = 0; k < 300; k++) { try { climb(n + 1); } catch (e) { caught = caught + 1; } }
  return most;
}
var retried = retry(1);

// Frames a class constructor opens, and a generator resumed inside
// another, stop as soon as a plain call's do.
var built = 0;
class Deep { constructor(n) { built = built + 1; if (n > 0) new Deep(n - 1); } }
try { new Deep(100000); } catch (e) { }
var resumed = 0;
function* nest(n) { resumed = resumed + 1; if (n > 0) yield* nest(n - 1); yield n; }
try { for (var v of nest(100000)) { } } catch (e) { }
var others = built <= first + 2 && resumed <= first + 2;

// A builtin that passes its arguments on puts a copy of them further up
// the register stack: three thousand calls of `call`, each with one
// argument fewer, are four and a half million registers, and the register
// limit stops them. (V8 moves the arguments in place and reaches the end,
// a TypeError: this one is the engine's own, not recorded from node.)
var calls = new Array(3000).fill(Function.prototype.call), passedOn = "returned";
try { Function.prototype.call.apply(Function.prototype.call, calls); } catch (e) { passedOn = e.name; }

console.log("call depth " + (first > 0 && retried > 0 ? "limited" : "unlimited") + "; same depth " + same + " of 300; retries no deeper " + (retried <= first + 1) + " of " + caught + "; constructors and generators no deeper " + others + "; arguments passed on " + passedOn);
