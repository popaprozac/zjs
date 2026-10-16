var log = [];
var order = [];
var p = new Promise(function (resolve, reject) { order.push("executor"); resolve(1); });
var q = p.then(function (v) { order.push("then"); });
order.push("sync");
var resolvedTwice = new Promise(function (resolve, reject) { resolve("first"); resolve("second"); reject("third"); });
log.push(order.join(), typeof Promise, Promise.name, Promise.length, typeof p.then, typeof q.then, q !== p, Object.prototype.toString.call(p), p instanceof Promise, Promise.prototype.constructor === Promise);
log.push(Promise.resolve(p) === p, Promise.resolve(1) instanceof Promise, Promise.reject(1) instanceof Promise, typeof Promise.all, typeof Promise.race, typeof Promise.allSettled, typeof Promise.any, Promise.prototype.then.length, Promise.prototype.catch.length, Promise.prototype.finally.length);
async function f(x) { order.push("f start"); var y = await x; order.push("f resumed"); return y; }
var fp = f(1);
async function thrower() { throw new Error("thrown"); }
var tp = thrower();
var arrow = async (a) => a;
class K { async m() { return 1; } }
log.push(order.join(), fp instanceof Promise, tp instanceof Promise, arrow(1) instanceof Promise, new K().m() instanceof Promise, typeof f, f.name, typeof arrow, f.length);
async function* ag() { yield 1; }
var agObject = ag();
log.push(typeof agObject.next, typeof agObject.return, typeof agObject.throw, Object.prototype.toString.call(agObject), typeof agObject[Symbol.asyncIterator], agObject[Symbol.asyncIterator]() === agObject, agObject.next() instanceof Promise, typeof Symbol.asyncIterator);
var errors = [];
try { Promise(); } catch (e) { errors.push(e.name); }
try { new Promise(); } catch (e) { errors.push(e.name); }
try { new Promise(1); } catch (e) { errors.push(e.name); }
try { Promise.prototype.then.call({}, function () {}); } catch (e) { errors.push(e.name); }
log.push(errors.join());
log.join("|");
