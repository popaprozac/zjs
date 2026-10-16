// Concatenation and joining of kilobyte strings.
function run() {
  var total = 0;
  var base = "";
  for (var i = 0; i < 200; i++) base += "abcde";
  for (var round = 0; round < 3000; round++) {
    var s = base + round;
    var t = s + s;
    var parts = [t, s, base];
    total = (total + t.length + parts.join("-").length) | 0;
  }
  return total;
}
var result = run();
