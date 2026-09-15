function add(a, b) { return a + b; }
function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }
var square = function (x) { return x * x; };
var named = function self(n) { return n <= 1 ? 1 : n * self(n - 1); };
var arrow = (a, b) => a * b;
var concise = x => x + 1;
function noReturn() { var y = 1; }
function early(v) { if (v) { return "yes"; } return "no"; }
function defaults(a, b = 10, c = a + b) { return a + b + c; }
function outerCount() { var count = 0; while (count < 3) count++; return count; }
"" + add(1, 2) + "," + fib(10) + "," + square(7) + "," + named(5) + "," + arrow(3, 4) + "," + concise(41) + "," + noReturn() + "," + early(1) + early(0) + "," + defaults(1) + "," + defaults(1, 2) + "," + defaults(1, 2, 3) + "," + outerCount();
