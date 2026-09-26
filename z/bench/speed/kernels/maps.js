// Map and Set with number and string keys.
var total = 0;
for (var round = 0; round < 40; round++) {
  var m = new Map();
  var s = new Set();
  for (var i = 0; i < 5000; i++) { m.set(i, i * 2); m.set("k" + i, i); s.add(i % 97); }
  for (var j = 0; j < 5000; j++) total = (total + m.get(j) + m.get("k" + j)) | 0;
  total = (total + s.size + m.size) | 0;
}
var result = total;
