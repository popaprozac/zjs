// Getters read in loops: a class's getter on its instances and on a
// subclass's, an object literal's own getter, Map's size, and a typed
// array's length. The work runs in a function, as most code does.
function run() {
  class Box {
    constructor(w, h) { this.w = w; this.h = h; }
    get area() { return this.w * this.h; }
  }
  class Square extends Box {
    constructor(s) { super(s, s); }
  }
  var boxes = [];
  for (var i = 0; i < 64; i++) boxes.push(i % 2 ? new Box(i, 2) : new Square(i));
  var counter = { n: 0, get next() { return ++this.n; } };
  var map = new Map([[1, 1], [2, 2], [3, 3]]);
  var bytes = new Uint8Array(32);
  var total = 0;
  for (var round = 0; round < 3000; round++) {
    for (var j = 0; j < boxes.length; j++) total = (total + boxes[j].area) | 0;
    for (var k = 0; k < 16; k++) total = (total + counter.next + map.size + bytes.length) | 0;
  }
  return total;
}
var result = run();
