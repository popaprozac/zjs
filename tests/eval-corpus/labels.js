var trace = "";
outer: for (var i = 0; i < 3; i++) {
  inner: for (var j = 0; j < 3; j++) {
    if (j == 1) continue outer;
    if (i == 2) break outer;
    trace += i + "" + j + ",";
  }
}
block: { trace += "a"; if (trace.length > 0) break block; trace += "b"; }
var k = 0;
loop: while (true) { k++; switch (k) { case 3: break loop; default: continue loop; } }
var w = 0;
do { w++; if (w < 5) continue; break; } while (true);
trace + "|" + k + "|" + w;
