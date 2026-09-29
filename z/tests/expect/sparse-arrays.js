// An element written far past an array's storage is kept by name, not
// by filling the gap; every index below 2**32 - 1 is an array index and
// moves the length.
var x = [];
var k = 1;
for (var i = 0; i < 32; i++) { k = k * 2; x[k - 2] = k; }
k = 1;
var ok = 0;
for (i = 0; i < 32; i++) { k = k * 2; if (x[k - 2] === k) ok++; }
console.log(ok, x.length, 4294967294 in x, x.hasOwnProperty("2147483648"), x[4294967295]);

var big = [];
big[4294967294] = "last";
console.log(big.length, big[4294967294], Object.keys(big).join());
big[4294967295] = "not an index";
console.log(big.length, Object.keys(big).join());
var c = [];
c.length = 4294967295;
console.log(c.length, new Array(4294967295).length, new Array(100000000).length);

// A sparse array reads, writes, deletes, and lists like any other.
var s = [1, 2, 3];
s[5000] = "far";
s[3000] = "mid";
s.name = "named";
console.log(s.length, s[5000], s[3000], s[4000], 3000 in s, 4000 in s, s.hasOwnProperty(5000));
console.log(Object.keys(s).join(), JSON.stringify(Object.getOwnPropertyDescriptor(s, "5000")));
var seen = [];
for (var key in s) seen.push(key);
console.log(seen.join());
s[5000] = "again";
console.log(s[5000], delete s[3000], 3000 in s, s.length);
s.push("pushed");
console.log(s.length, s[5001], s.indexOf("pushed"), s.lastIndexOf("far"), s.includes("again"));
var visited = 0;
s.forEach(function () { visited++; });
console.log(visited, s.filter(function (v) { return typeof v === "string"; }).join("|"), s.join("").length);
console.log(s.map(function (v) { return v; }).length, Object.keys(s.map(function (v) { return v; })).length);

// Shortening deletes the elements past the new length.
s.length = 4000;
console.log(s.length, s[5000], 5001 in s, Object.keys(s).join());
s.length = 2;
console.log(s.length, JSON.stringify(s), s.name);

// Defined, frozen, and non-configurable elements past the storage.
var d = [];
Object.defineProperty(d, 9999, { value: "fixed", writable: false, configurable: false, enumerable: true });
console.log(d.length, d[9999]);
d[9999] = "changed";
console.log(d[9999], delete d[9999]);
d.length = 10;
console.log(d.length, d[9999]);
var f = [];
f[20000] = 1;
Object.freeze(f);
f[20000] = 2;
f[30000] = 3;
console.log(f[20000], f[30000], f.length, Object.isFrozen(f));
var backwards = [];
for (var b = 2999; b >= 0; b--) backwards[b] = b;
console.log(backwards.length, backwards[0], backwards[2999], backwards.reduce(function (t, v) { return t + v; }, 0));

// A sparse array as another's prototype: its far elements are inherited,
// and a setter there still runs for a write to the absent index.
var proto = [];
proto[7000] = "inherited";
Object.defineProperty(proto, 8000, { set: function (v) { log.push("set " + v); }, configurable: true });
var log = [];
var child = [];
Object.setPrototypeOf(child, proto);
console.log(child[7000], 7000 in child, child.hasOwnProperty(7000));
child[8000] = "via setter";
child.push("pushed");
console.log(log.join(), child.length, child[0], child.hasOwnProperty(8000));
var plain = [];
for (var p = 0; p < 10; p++) plain.push(p);
console.log(plain.join(), plain.length);
