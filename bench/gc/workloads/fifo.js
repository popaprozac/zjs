// A sliding window: 100,000 records live at any time, each replaced in
// the order it was made, so every record outlives the young generation
// and then dies. All garbage is old garbage.
function run() {
  var size = 100000, ring = [], total = 0;
  for (var i = 0; i < size; i++) ring.push({ id: i, data: [i, i + 1], label: "r" + i });
  for (var j = 0; j < 1500000; j++) {
    var at = j % size;
    total = (total + ring[at].data[1]) | 0;
    ring[at] = { id: j, data: [j, j + 1], label: "r" + (j & 4095) };
  }
  return total;
}
var result = run();
(typeof console !== "undefined" ? console.log : print)(String(result));
