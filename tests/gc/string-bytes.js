// Strings too long for the byte arena, each with a buffer of its own and
// a cell or two: 40 MB of them if none were given back. In the first
// loop each dies before the next is made. In the second a ring keeps the
// last thirty, so each is old by the time it dies and only a full
// collection gives it back.
var total = 0;
for (var i = 0; i < 400; i++) {
  var s = "x".repeat(50000 + i);
  total += s.length;
}
var ring = [];
for (var j = 0; j < 200; j++) ring[j % 30] = "y".repeat(50000) + j;
var intact = 0;
for (var k = 0; k < 30; k++) {
  var t = ring[k];
  if (t.length === 50003 && t.charCodeAt(49999) === 121 && Number(t.slice(50000)) % 30 === k) intact++;
}
console.log("strings", total, intact);
