// Calls read the callee, the receiver, and a lone argument where they
// are when nothing evaluated after them can assign them; when an
// argument can, the value read first is the one used.
var out = [];
function run() {
  var f = function (x) { return "f" + x; };
  var g = function (x) { return "g" + x; };
  out.push(f((f = g) && 1), f(2));
  var o = { tag: "o", m: function (x) { return this.tag + x; } };
  var p = { tag: "p", m: function (x) { return this.tag + "!" + x; } };
  out.push(o.m(o = p), o.m(2), o["m"](o = { tag: "q", m: o.m }));
  function C(v) { this.v = v; }
  function D(v) { this.v = -v; }
  var K = C;
  out.push(new K(K = D).v === D, new K(3).v);
  var n = 5;
  function bump(a) { a = a + 1; return a; }
  out.push(bump(n), n);
  function strictArgs(a) { "use strict"; a = 9; return arguments.length + ":" + arguments[0]; }
  out.push(strictArgs(n));
  var list = [3, 1, 2];
  var sorter = function (a, b) { return a - b; };
  out.push(list.sort(sorter).join(""), [n].concat(n).join(""));
  var self = { count: 0, add: function (k) { this.count += k; return this; } };
  out.push(self.add(1).add(2).count);
  var Point = function (x, y) { this.x = x; this.y = y; };
  var pt = new Point(n, n * 2);
  out.push(pt.x + "," + pt.y);
}
run();
// An object literal built in its argument slot, with literals among its
// values, and arguments after it: their slots stay its own.
function four(a, b, c, d) { return [a, b, JSON.stringify(c), JSON.stringify(d)].join("/"); }
out.push(four(1, "s", { get: { name: "g", length: 0 }, set: { name: "s", length: 1 } }, { label: "L" }));
console.log(out.join(" "));
