var a = 1, b, c = 2 + 3;
let d = [1, 2], e;
const f = 4;
{ var g = 5; { let h = 6; } }
if (a) b = 1; else if (c) d = 2; else { e = 3; }
while (a < 10) a++;
do { a--; } while (a > 0)
with (obj) { x = 1; }
;
outer: inner: while (true) { a = 1; }
label: { b = 2; }
a; b, c;
