var log = [];
var [a, b = 2, , d, ...rest] = [1, undefined, 3, 4, 5, 6];
var { x, y: renamed, z = "dz", ...others } = { x: 10, y: 20, p: 1, q: 2 };
var { ["comp" + "uted"]: comp } = { computed: 30 };
log.push(a, b, d, rest.join(), x, renamed, z, comp, Object.keys(others).join());
let [nested1, [nested2, { deep }]] = [1, [2, { deep: 3 }]];
const { inner: { value: constValue = 9 } = {} } = {};
log.push(nested1, nested2, deep, constValue);
function params([first, second], { key, missing = "dflt" } = {}, ...tail) { return first + second + ":" + key + ":" + missing + ":" + tail.length; }
log.push(params([1, 2], { key: "k" }, 7, 8), params([3, 4]));
var swapA = 1, swapB = 2;
[swapA, swapB] = [swapB, swapA];
var target = {};
({ m: target.member, n: target["computedKey"] } = { m: "M", n: "N" });
var assigned = ([target.first, ...target.more] = [1, 2, 3]);
log.push(swapA, swapB, target.member, target.computedKey, target.first, target.more.join(), Array.isArray(assigned));
var pairs = "";
for (var [k, v] of [["one", 1], ["two", 2]]) pairs += k + "=" + v + ";";
for (const { id, tags: [firstTag] } of [{ id: 7, tags: ["t1", "t2"] }]) pairs += id + firstTag;
for (var [ch] in { ab: 1 }) pairs += "|" + ch;
log.push(pairs);
var caughtMessage = "";
try { throw { message: "boom", code: 42 }; } catch ({ message, code }) { caughtMessage = message + code; }
log.push(caughtMessage);
function capture() { let [inner1, inner2] = [1, 2]; return function () { return inner1 + inner2; }; }
log.push(capture()());
var defaultsSeen = "";
var [ev = defaultsSeen += "a", ev2 = defaultsSeen += "b"] = [undefined, null];
log.push(defaultsSeen, ev, ev2);
var closed = 0;
var iterable = { [Symbol.iterator]: function () { var i = 0; return { next: function () { i++; return { value: i, done: false }; }, return: function () { closed++; return {}; } }; } };
var [i1, i2] = iterable;
var [...allOfThree] = [1, 2, 3];
log.push(i1, i2, closed, allOfThree.length);
var errors = [];
try { var { fail } = null; } catch (e) { errors.push(e.name); }
try { var [nope] = 5; } catch (e) { errors.push(e.name); }
try { (function ({ req }) {})(); } catch (e) { errors.push(e.name); }
log.push(errors.join());
log.join("|");
