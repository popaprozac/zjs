function f(a, b = 2, ...rest) { return a + b; }
function g() { return; }
function* gen(x) { yield x; yield* other; yield; }
async function af(p) { await p; return await q; }
var fe = function named(a) { return a; };
var anon = function () {};
var ge = function* () { yield 1; };
var ae = async function (x) { await x; };
var arrow = x => x * 2;
var arrows = (a, b) => { return a + b; };
var noArgs = () => 42;
var asyncArrow = async (a) => await a;
var asyncSingle = async y => y;
var nested = a => b => c => a + b + c;
f(x => x, (a, b) => a, function () {});
function withDefaults(a = 1, { b, c: d = 3 } = {}, [e, , f = 4, ...g] = []) {}
