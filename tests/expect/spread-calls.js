// A spread call's arguments are on the register stack only while the call
// runs, however the callee's frame ends: a return, a constructor's return,
// a throw, a generator's or an async function's suspension, an error
// before the frame opens. The callee sees all of them (parameters, rest,
// arguments) through calls of its own. gc-check.sh runs this file as
// well, for how far the register stack grew.
var log = [];
function sum3(a, b, c) { return a + b + c; }
function Point(x, y) { this.x = x; this.y = y; }
class Base { constructor(a, b) { this.sum = a + b; } }
class Derived extends Base { constructor(...args) { super(...args); this.count = args.length; } }
var holder = { base: 100, add(a, b) { return this.base + a + b; } };
function tail(first, ...rest) { var before = sum3(...rest); return first + before + rest.length + rest[rest.length - 1]; }
function counted(a) { var inner = sum3(1, 2, 3) + sum3(...[4, 5, 6]); return arguments.length * 1000 + arguments[4] + inner; }
function mapped(a, b) { a = 7; arguments[1] = 8; return arguments[0] * 10 + b; }
function* gen(a, b, c) { yield a; yield b + arguments.length; return c; }
async function later(a, b) { var got = await a; return got + b + arguments.length; }
function thrower(a, b) { throw new RangeError("thrown " + (a + b)); }
var arrow = (a, b) => a + b;
function depth(n, ...rest) { return n == 0 ? rest.join("") : depth(...[n - 1, ...rest, n]); }
function run(rounds) {
  var three = [3, 1, 2], five = [1, 2, 3, 4, 5], total = 0, caught = 0, pending = [];
  // A builtin that runs JavaScript between reading two of its arguments.
  var six = { valueOf() { return sum3(...three); } };
  for (var i = 0; i < rounds; i++) {
    total += sum3(...three) + holder.add(...three) + tail(...five) + counted(...five) + mapped(...three);
    total += new Point(...three).y + new Derived(...five).count + new Derived(...three).sum;
    total += Math.max(...five) + sum3.bind(null, 1)(...three) + new Array(...five).length + arrow(...three);
    total += Math.max(...[six, 50, 7]) + new Date(...[six, 0, 15]).getDate();
    var it = gen(...three);
    total += it.next().value + it.next().value + it.next().value;
    pending.push(later(...five));
    try { thrower(...three); } catch (e) { caught += e.message.length; }
    try { new arrow(...three); } catch (e) { caught += e instanceof TypeError ? 1 : 0; }
    try { Base(...three); } catch (e) { caught += e instanceof TypeError ? 1 : 0; }
    try { three(...five); } catch (e) { caught += e instanceof TypeError ? 1 : 0; }
  }
  log.push("total " + total, "caught " + caught, "depth " + depth(...[9]));
  return Promise.all(pending).then(function (values) { var sum = 0; for (var v of values) sum += v; log.push("later " + sum); });
}
run(500).then(function () { console.log(log.join("\n")); });
