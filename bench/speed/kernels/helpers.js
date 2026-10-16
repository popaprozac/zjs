// Calls to small functions, as most code is built from: arithmetic
// helpers, a predicate, a property accessor. The work runs in a function,
// as most code does.
function run() {
  function square(x) { return x * x; }
  function clamp(x, low, high) { return x < low ? low : x > high ? high : x; }
  function isEven(n) { return n % 2 === 0; }
  function area(rect) { return rect.w * rect.h; }
  var rects = [];
  for (var i = 0; i < 64; i++) rects.push({ w: i % 7 + 1, h: i % 5 + 1 });
  var total = 0;
  for (var j = 0; j < 600000; j++) {
    total = (total + square(j & 255) + clamp(j & 1023, 100, 900) + area(rects[j & 63])) | 0;
    if (isEven(j)) total = (total + 1) | 0;
  }
  return total;
}
var result = run();
