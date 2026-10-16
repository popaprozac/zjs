// OPS 1000000 : short-lived objects against a retained set of 300,000 objects
var held = [];
for (var i = 0; i < 300000; i++) { held.push({ id: i, next: null }); }
for (var i = 1; i < held.length; i++) { held[i].next = held[i - 1]; }
var t = 0;
for (var i = 0; i < 1000000; i++) { var o = { a: i, b: [i] }; t += o.b.length; }
console.log(t + held.length);
