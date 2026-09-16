// Allocation pressure through ordinary collections (no gc() call): keys
// dropped as they go must not accumulate in a long-lived WeakMap and
// WeakSet. The runner reads --stats: live cells stay small, the cleared
// count is close to the dropped count, and the held keys are still there.
var map = new WeakMap(), set = new WeakSet();
var held = [];
for (var i = 0; i < 100; i++) { var h = { i: i }; held.push(h); map.set(h, { keep: i }); set.add(h); }
for (var round = 0; round < 200000; round++) {
  var key = { round: round };
  map.set(key, { payload: [round, round + 1] });
  set.add(key);
}
var ok = true;
for (var j = 0; j < held.length; j++) { if (map.get(held[j]).keep !== j || !set.has(held[j])) ok = false; }
console.log(ok ? "held entries intact" : "held entries lost");
