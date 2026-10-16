// OPS 3000000 : short-lived objects, arrays, and strings against a tiny live set
var keep = null, t = 0;
for (var i = 0; i < 1000000; i++) { var o = { a: i, b: i + 1 }; var a = [i, o.a]; var s = "k" + (i & 1023); keep = o; t += a.length + s.length + o.b; }
console.log(t);
