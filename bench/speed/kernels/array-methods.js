// Array methods that take no callback, on 64 numbers and 64 strings:
// searches from both ends, copies, and a reverse. (`arrays` has the
// methods that take one.) The work runs in a function, as most code
// does.
function run() {
  var numbers = [], words = [], needles = [];
  for (var k = 0; k < 64; k++) { numbers.push(k); words.push("w" + k); }
  for (var n = 0; n < 8; n++) needles.push("w" + (n * 9));
  var total = 0;
  for (var i = 0; i < 20000; i++) {
    total = (total + numbers.indexOf(i & 63) + numbers.lastIndexOf(i & 31)) | 0;
    if (numbers.includes(63 - (i & 63))) total = (total + 1) | 0;
    total = (total + words.indexOf(needles[i & 7])) | 0;
    total = (total + numbers.slice(i & 31).length + numbers.concat(words).length) | 0;
    numbers.reverse();
  }
  return total + numbers[0];
}
var result = run();
