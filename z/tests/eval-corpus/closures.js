function makeCounter(start) {
  var count = start;
  return {
    next: function () { count = count + 1; return count; },
    peek: function () { return count; }
  };
}
var c1 = makeCounter(10);
var c2 = makeCounter(100);
c1.next(); c1.next(); c2.next();
var counters = c1.peek() + ":" + c2.peek();
function adder(a) { return function (b) { return function (c) { return a + b + c; }; }; }
var deep = adder(1)(2)(3);
function outer() {
  var x = "x";
  function middle() {
    function inner() { return x + y; }
    var y = "y";
    return inner;
  }
  return middle()();
}
var chain = outer();
var fns = [];
for (var i = 0; i < 3; i = i + 1) { fns[i] = function () { return i; }; }
var shared = fns[0]() + fns[1]() + fns[2]();
var fact = function self(n) { return n <= 1 ? 1 : n * self(n - 1); };
function applyTwice(f, v) { return f(f(v)); }
var scale = 3;
var scaled = applyTwice(function (v) { return v * scale; }, 2);
let top = 5;
function readTop() { return top; }
top = 6;
var caught = "";
function thrower() {
  try { throw "boom"; } catch (e) { return function () { return e; }; }
}
caught = thrower()();
counters + "|" + deep + "|" + chain + "|" + shared + "|" + fact(5) + "|" + scaled + "|" + readTop() + "|" + caught;
