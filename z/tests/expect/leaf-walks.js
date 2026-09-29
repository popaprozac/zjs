// Array builtins call a leaf callback with its arguments written straight
// into its registers; a leaf that leaves its fast paths runs in full with
// the same arguments, and parameters past those passed are undefined.
var nums = [5, 1, 4, 2, 3];
console.log(nums.map(function (x) { return x * 2; }).join(), nums.filter(function (x) { return x % 2 === 1; }).join());
console.log(nums.some(function (x) { return x > 4; }), nums.every(function (x) { return x > 0; }), nums.every(function (x) { return x > 1; }));
console.log(nums.find(function (x) { return x < 3; }), nums.findIndex(function (x) { return x === 4; }), nums.findLast(function (x) { return x > 3; }));
console.log(nums.reduce(function (s, x) { return s + x; }, 0), nums.reduce(function (s, x, i) { return s + x * i; }, 0), nums.reduceRight(function (s, x) { return s * 10 + x; }, 0));
console.log(nums.reduce(function (s, x) { return s + x; }), nums.map(function (x, i) { return i; }).join());
console.log(nums.map(function (x, i, a, extra) { return extra === undefined; }).join());
console.log(nums.slice().sort(function (a, b) { return a - b; }).join(), nums.slice().sort(function (a, b) { return b - a; }).join());
console.log(nums.slice().sort(function (a, b, c) { return c === undefined ? a - b : 0; }).join());

// Values that leave the fast paths: strings, objects, doubles.
var mixed = [3, "7", 2.5, { valueOf: function () { return 10; } }, -1];
console.log(mixed.map(function (x) { return x * 2; }).join(), mixed.map(function (x) { return x + 1; }).join());
console.log(mixed.filter(function (x) { return x > 2; }).length, mixed.reduce(function (s, x) { return s + x; }, 0));
var words = ["pear", "fig", "apple", "kiwi"];
console.log(words.slice().sort(function (a, b) { return a < b ? -1 : a > b ? 1 : 0; }).join(), words.map(function (w) { return w.length; }).join());
console.log(words.slice().sort(function (a, b) { return a.length - b.length; }).join());

// A leaf that bails midway through a long walk, and a thrown error.
var long = [];
for (var i = 0; i < 1000; i++) long.push(i === 500 ? "x" : i);
console.log(long.map(function (x) { return x + 1; })[500], long.reduce(function (s, x) { return s + (x === "x" ? 0 : x); }, 0));
try { [1, 2].map(function (x) { return x.y.z; }); } catch (e) { console.log(e instanceof TypeError); }
console.log([3, 1, 2].sort(function (a, b) { return a - b; }).map(function (x) { return x * x; }).filter(function (x) { return x > 1; }).reduce(function (s, x) { return s + x; }, 0));

// An element a getter makes is kept alive while it is filtered or mapped.
var made = [1, 2, 3, 4, 5, 6];
Object.defineProperty(made, 2, { get: function () { return { v: "made" + this.length }; } });
var picked = made.filter(function (x) { return x !== 0; });
console.log(picked.length, picked[2].v, made.map(function (x) { return x; })[2].v);
var sparse = [1, , 3, , 5];
console.log(sparse.map(function (x) { return x * 2; }).length, 1 in sparse.map(function (x) { return x * 2; }), sparse.filter(function (x) { return x > 1; }).join());
