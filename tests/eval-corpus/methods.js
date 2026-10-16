var counter = {
  count: 0,
  step: 2,
  increment: function () { this.count = this.count + this.step; return this; },
  read: function (label) { return label + "=" + this.count; }
};
counter.increment().increment();
var picked = counter["read"]("count");
function Point(x, y) { this.x = x; this.y = y; }
Point.prototype.norm = function () { return this.x * this.x + this.y * this.y; };
var p = new Point(3, 4);
var q = new Point(1);
var made = p.norm() + ":" + (p.constructor === Point) + ":" + typeof p + ":" + (q.y === undefined);
function Boxed(v) { this.v = v; return { replaced: v * 2 }; }
var b = new Boxed(21);
picked + "|" + made + "|" + b.replaced + ":" + b.v;
