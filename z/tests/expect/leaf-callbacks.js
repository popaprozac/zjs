// A callback that is straight-line arithmetic, comparisons, and cached
// reads runs without a frame; anything off those paths runs in full.
function show() { var p = []; for (var i = 0; i < arguments.length; i++) p.push(Object.is(arguments[i], -0) ? "-0" : typeof arguments[i] === "object" ? JSON.stringify(arguments[i]) : String(arguments[i])); console.log(p.join(" ")); }

// Numbers, then values that leave the fast paths partway through.
show([1, 2, 3].map(function (x) { return x * 2 + 1; }).join());
show([1, "2", 3, null, undefined, true].map(function (x) { return x * 2; }).join());
show(["b", "a", 3, 1, "c", 2].sort(function (a, b) { return a < b ? -1 : a > b ? 1 : 0; }).join());
show([3, 1, 2].sort(function (a, b) { return b - a; }).join());
show([0, -1, 2].map(function (x) { return x * -0; }).map(function (v) { return Object.is(v, -0) ? "-0" : v; }).join());
show([1.5, NaN, Infinity].map(function (x) { return x % 1; }).join());
show([5, 6].map(function (x, i) { return i; }).join(), [5, 6].map(function (x, i, a, extra) { return extra; }).join());
show([10, 20, 30].reduce(function (s, x) { return s + x; }), [].reduce(function (s, x) { return s + x; }, "empty"));
show(["x", "y"].reduce(function (s, x) { return s + x; }, ""));

// Property reads: cached data, a getter, a miss that fills the cache, a
// prototype's data.
var points = [{ x: 1 }, { x: 2 }, { x: 3 }];
show(points.map(function (p) { return p.x * 10; }).join());
var gets = 0;
var withGetter = { get x() { gets++; return 7; } };
show([withGetter, withGetter].map(function (p) { return p.x + 1; }).join(), gets);
function Proto() {}
Proto.prototype.v = 9;
show([new Proto(), { v: 1 }].map(function (o) { return o.v; }).join());
show([{ a: 1 }, { b: 2 }, { a: 3 }].map(function (o) { return o.a === undefined; }).join());

// Elements: present, a hole, out of range.
var rows = [[1, 2], [3, , 5], [6]];
show(rows.map(function (r) { return r[1]; }).join());
Array.prototype[1] = "proto";
show(rows.map(function (r) { return r[1]; }).join());
delete Array.prototype[1];

// Branches, booleans, strict equality, bitwise.
show([1, 2, 3, 4, 5, 6].filter(function (x) { return x % 2 === 0; }).join());
show([1, 2, 3, 4].filter(function (x) { return !(x > 2); }).join());
show([0, 1, 2].map(function (x) { return x === 1 ? "one" : x !== 0 ? "many" : "none"; }).join());
show([7, 8].map(function (x) { return (x | 1) ^ 2 & 255; }).join());
show([1, 2, 3].some(function (x) { return x >= 3; }), [1, 2, 3].every(function (x) { return x <= 2; }));
show([3, 1, 2].findIndex(function (x) { return x === 1; }), [3, 1, 2].find(function (x) { return x < 3; }));

// Arrow functions, array-likes, call and apply, a default parameter.
show([1, 2].map((x) => x + 0.5).join(), Array.prototype.map.call({ length: 2, 0: 4, 1: 5 }, function (x) { return x * x; }).join());
show(Math.max.apply(null, [1, 2, 3]), (function (a, b) { return a - b; }).call(null, 10, 4));
show([1, undefined].map(function (x = 5) { return x + 1; }).join());

// Many calls, and allocation between them.
var total = 0;
for (var r = 0; r < 200; r++) {
  var made = [];
  for (var i = 0; i < 100; i++) made.push({ v: i });
  total += made.map(function (o) { return o.v; }).reduce(function (s, v) { return s + v; }, 0);
}
show(total);
