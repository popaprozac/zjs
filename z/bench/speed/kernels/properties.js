// Monomorphic property reads and writes on class instances.
class Vec { constructor(x, y) { this.x = x; this.y = y; } }
var points = [];
for (var i = 0; i < 1000; i++) points.push(new Vec(i, i * 2));
var sum = 0;
for (var round = 0; round < 1500; round++) {
  for (var j = 0; j < points.length; j++) {
    var p = points[j];
    p.x = p.x + 1;
    sum = (sum + p.x + p.y) | 0;
  }
}
var result = sum;
