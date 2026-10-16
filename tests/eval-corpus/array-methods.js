var log = [];
var a = [1, 2, 3, 4, 5];
log.push(a.at(-1), a.at(0), a.at(9), a.includes(3), a.includes(NaN), [NaN].includes(NaN), a.indexOf(3), a.indexOf(3, -2), a.lastIndexOf(3), a.lastIndexOf(9));
log.push(a.find(function (x) { return x > 2; }), a.findIndex(function (x) { return x > 2; }), a.findLast(function (x) { return x < 4; }), a.findLastIndex(function (x) { return x > 9; }));
log.push(a.reduce(function (s, x) { return s + x; }), a.reduce(function (s, x) { return s + x; }, 10), a.reduceRight(function (s, x) { return s + x; }, ""));
log.push([1, [2, [3, [4]]]].flat().length, [1, [2, [3, [4]]]].flat(Infinity).join(), [1, 2].flatMap(function (x) { return [x, x * 10]; }).join());
var b = [1, 2, 3];
log.push(b.push(4, 5), b.pop(), b.shift(), b.unshift(0, 1), b.join());
log.push([3, 1, 2].sort().join(), [10, 9, 1].sort().join(), [10, 9, 1].sort(function (x, y) { return x - y; }).join(), [undefined, 3, , 1].sort().length, ["b", undefined, "a"].sort().join());
var stable = [{ k: 1, v: "a" }, { k: 0, v: "b" }, { k: 1, v: "c" }, { k: 0, v: "d" }];
log.push(stable.sort(function (x, y) { return x.k - y.k; }).map(function (e) { return e.v; }).join(""));
log.push([1, 2, 3, 4, 5].copyWithin(0, 3).join(), [1, 2, 3].fill(0, 1).join(), new Array(3).fill(7).join(), [1, 2, 3].reverse().join());
var sp = [1, 2, 3, 4, 5];
log.push(sp.splice(1, 2, "x", "y", "z").join(), sp.join(), sp.splice(-1).join(), sp.splice(0, 0, "s").length, sp.join());
log.push([1, 2].concat([3, 4], 5, [[6]]).length, [1].concat({ length: 1, 0: "o", [Symbol.isConcatSpreadable]: true }).join());
log.push(Array.prototype.map.call({ length: 2, 0: "a", 1: "b" }, function (x) { return x + x; }).join(), Array.prototype.indexOf.call({ length: 3, 2: "z" }, "z"), Array.prototype.every.call("aaa", function (c) { return c === "a"; }));
log.push([1, 2, 3].toReversed().join(), [3, 1, 2].toSorted().join(), [1, 2, 3].toSpliced(1, 1, "q").join(), [1, 2, 3].with(1, "w").join(), [1, 2, 3].with(-1, "e").join());
log.push([1, [2, 3]].toString(), [1, null, undefined, 2].join(), String([{ toString: function () { return "T"; } }]), [1.5, 2].toLocaleString());
var holes = [1, , 3];
var visited = [];
holes.forEach(function (v, i) { visited.push(i); });
log.push(visited.join(), holes.map(function (v) { return v * 2; }).length, 1 in holes.map(function (v) { return v; }), holes.filter(function () { return true; }).length, holes.some(function (v) { return v === undefined; }), holes.every(function (v) { return v !== undefined; }), holes.find(function (v) { return v === undefined; }) === undefined, holes.findIndex(function (v) { return v === undefined; }));
var errors = [];
try { [].reduce(function () {}); } catch (e) { errors.push(e.name); }
try { [1].forEach(1); } catch (e) { errors.push(e.name); }
try { [1].sort(1); } catch (e) { errors.push(e.name); }
try { Array.prototype.push.call(null); } catch (e) { errors.push(e.name); }
try { [1].with(5, 0); } catch (e) { errors.push(e.name); }
log.push(errors.join(), Array.prototype.concat.length, Array.prototype.push.length, Array.prototype.splice.length);
log.join("|");
