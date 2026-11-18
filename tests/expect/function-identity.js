// Every evaluation of a function expression or declaration makes a new
// function object with its own prototype, even when the function refers
// to nothing around it.
function make() { return function () { return 1; }; }
var f1 = make(), f2 = make();
console.log(f1 === f2, f1.prototype === f2.prototype);
f1.prototype.k = 1;
f1.own = "f1";
console.log(f2.prototype.k, f2.own, f1(), f2());

function declares() { function inner() {} return inner; }
console.log(declares() === declares());

function named() { return function self() { return self; }; }
var n1 = named(), n2 = named();
console.log(n1 === n2, n1() === n1, n2() === n2);

function kinds() {
  return [
    function* () {}, async function () {}, async function* () {}, () => {},
    { m() {} }.m, Object.getOwnPropertyDescriptor({ get g() { return 1; } }, "g").get,
  ];
}
var a = kinds(), b = kinds();
console.log(a.map(function (fn, i) { return fn === b[i]; }).join(" "));
console.log(a[0].prototype === b[0].prototype, a[2].prototype === b[2].prototype);

// In a loop, at the top level and in a block.
var looped = [];
for (var i = 0; i < 3; i++) looped.push(function () {});
console.log(looped[0] === looped[1], looped[1] === looped[2]);
var blocks = [];
for (var j = 0; j < 2; j++) { function inBlock() {} blocks.push(inBlock); }
console.log(blocks[0] === blocks[1]);
// A loop's test and update run once an iteration too.
var tested = [];
while (tested.push(function () {}) < 3);
var updated = [];
for (var u = 0; u < 3; updated.push(function () {}), u++);
var bottom = [];
do; while (bottom.push(function () {}) < 2);
console.log(tested[0] === tested[1], updated[0] === updated[1], bottom[0] === bottom[1]);
// Top-level code that is compiled each time it runs.
console.log(eval("(function () {})") === eval("(function () {})"), new Function("") === new Function(""));
var evaluated = [];
for (var e = 0; e < 2; e++) evaluated.push((0, eval)("(function () {})"));
console.log(evaluated[0] === evaluated[1]);

// The class-factory pattern (Prototype's Class.create): one constructor
// and one prototype per class.
var Class = { create: function () { return function () { this.initialize.apply(this, arguments); }; } };
var Vector = Class.create();
Vector.prototype = { initialize: function (x) { this.x = x; }, magnitude: function () { return Math.abs(this.x); } };
var Color = Class.create();
Color.prototype = { initialize: function (r) { this.r = r; }, brighter: function () { return this.r + 1; } };
console.log(Vector === Color, new Vector(-3).magnitude(), new Color(4).brighter());
