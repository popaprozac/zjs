var total = 0, i = 0;
while (i < 10) { i = i + 1; if (i % 2) continue; if (i > 8) break; total += i; }
var j = 0; do { j++; } while (j < 3);
for (var k = 0, m = 0; k < 5; k++) { m += k; }
var text = "";
if (total == 20) text = "even-sum"; else text = "other";
text + ":" + total + ":" + j + ":" + m;
