// Exact reclamation under forced collections: 1000 keys dropped from a
// WeakMap and a WeakSet, then gc(): the runner expects weak-cleared to
// be exactly 2000 and the passes count reported.
var map = new WeakMap(), set = new WeakSet();
var keep = {};
map.set(keep, "kept"); set.add(keep);
for (var i = 0; i < 1000; i++) { var k = {}; map.set(k, i); set.add(k); }
k = null;
gc();
console.log(map.get(keep) + "," + set.has(keep));
