var log = [];
function* counter(start) { var i = start; while (true) { var sent = yield i; if (sent) i = sent; else i++; } }
var c = counter(5);
log.push(c.next().value, c.next().value, c.next(20).value, c.next().value, typeof c.next, c[Symbol.iterator]() === c, Object.prototype.toString.call(c));
function* finite() { yield "a"; yield "b"; return "end"; }
var f = finite();
var r1 = f.next(), r2 = f.next(), r3 = f.next(), r4 = f.next();
log.push(r1.value, r1.done, r2.value, r3.value, r3.done, r4.value, r4.done);
log.push([...finite()].join(), Array.from(finite()).length);
var collected = "";
for (var v of finite()) collected += v;
log.push(collected);
function* withTry() { try { yield 1; yield 2; } catch (e) { yield "caught:" + e; } yield 3; }
var t = withTry();
log.push(t.next().value, t.throw("boom").value, t.next().value, t.next().done);
var early = withTry();
early.next();
log.push(early.return("bye").value, early.return("bye").done, early.next().done);
function* delegating() { yield 0; yield* [1, 2]; yield* finite(); yield 9; }
log.push([...delegating()].join());
function* usesThis() { yield this.tag; }
var holder = { tag: "T", gen: usesThis };
log.push(holder.gen().next().value);
function* closure() { var local = 1; var fn = function () { return local; }; yield fn; local = 2; yield fn; }
var cl = closure();
var fn1 = cl.next().value; var fn2 = cl.next().value;
log.push(fn1(), fn2());
var errors = [];
try { var running = (function* () { running.next(); yield 1; })(); running.next(); } catch (e) { errors.push(e.name); }
try { finite.prototype.next.call({}); } catch (e) { errors.push(e.name); }
var done = finite(); done.next(); done.next(); done.next();
try { done.throw(new RangeError("late")); } catch (e) { errors.push(e.name); }
log.push(errors.join(), typeof finite.prototype, Object.getPrototypeOf(finite.prototype) === Object.getPrototypeOf(Object.getPrototypeOf(f)));
function* args() { yield arguments.length; yield arguments[1]; }
var ag = args(7, 8);
log.push(ag.next().value, ag.next().value);
log.join("|");
