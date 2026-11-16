// One name read off receivers of several shapes, where a site's cache
// holds one: a method called on objects of two classes and of four, an
// array's and a string's method of one name in one function, and a field
// read off six shapes. The work runs in a function, as most code does.
function run() {
  class Circle { constructor(r) { this.r = r; } area() { return this.r * 3; } }
  class Square { constructor(s) { this.s = s; } area() { return this.s * this.s; } }
  class Strip { constructor(l) { this.l = l; } area() { return this.l; } }
  class Dot { area() { return 1; } }
  var two = [], four = [], records = [];
  for (var k = 0; k < 8; k++) {
    two.push(k % 2 ? new Circle(k) : new Square(k));
    four.push(k % 4 == 0 ? new Circle(k) : k % 4 == 1 ? new Square(k) : k % 4 == 2 ? new Strip(k) : new Dot());
    var record = {};
    for (var pad = 0; pad < k % 6; pad++) record["pad" + pad] = pad;
    record.v = k;
    records.push(record);
  }
  var list = [3, 1, 2], text = "abc";
  var total = 0;
  for (var i = 0; i < 300000; i++) {
    total = (total + two[i & 7].area() + four[i & 7].area()) | 0;
    total = (total + list.indexOf(2) + text.indexOf("c")) | 0;
    total = (total + records[i & 7].v) | 0;
  }
  return total;
}
var result = run();
