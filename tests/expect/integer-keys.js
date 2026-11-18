// An integer key names the property its decimal string does, on an
// ordinary object and an arguments object alike, below the integers whose
// atoms are kept and past them.
var out = [];
function put(o, i, v) { o[i] = v; }
function get(o, i) { return o[i]; }
var o = {};
put(o, 9, "nine"); put(o, 3, "three"); put(o, "1", "one"); put(o, 1023, "c"); put(o, 1024, "d"); put(o, -1, "m"); put(o, 1.5, "f"); put(o, 2147483647, "g");
out.push([get(o, "9"), get(o, 3), get(o, 1), get(o, 0), get(o, "1023"), get(o, 1024), get(o, "-1"), get(o, "1.5"), get(o, 2147483647)].join(), Object.keys(o).join());
function args() { return [arguments[0], arguments["1"], arguments.length, Object.keys(arguments).join(), 2 in arguments, "3" in arguments].join("|"); }
out.push(args("x", "y", "z"));
function many() { return arguments[1050] + arguments["999"] + arguments.length; }
var big = []; for (var i = 0; i < 1100; i++) big.push(i);
out.push(many.apply(null, big));
function Point(x, y) { this.initialize.apply(this, arguments); }
Point.prototype.initialize = function (x, y) { this.x = x; this.y = y; };
out.push(JSON.stringify(new Point(3, 4)), JSON.stringify(new Point(5, 6)));
console.log(out.join("\n"));

// A key's atom stays itself after a collection that frees whatever else
// held it, though the cells made after it take freed handles.
var out = [];
var probe = {};
for (var k = 500; k < 540; k++) out.push(get(probe, k));
out = [out.length];
if (typeof gc === "function") gc();
var fill = []; for (var k = 0; k < 4000; k++) fill.push("s" + k);
var later = {}; for (var k = 500; k < 540; k++) put(later, String(k), k * 2);
var hits = 0; for (var k = 500; k < 540; k++) if (get(later, k) === k * 2) hits++;
out.push(hits, Object.keys(later).length, Object.keys(later)[39], get(later, 539), String(539) in later);
console.log(out.join("\n"));
