// OPS 3000000 : short-lived objects after two million objects were held and dropped
function spike() { var held = []; for (var i = 0; i < 2000000; i++) { held.push({ id: i, pair: [i, i] }); } return held.length; }
var n = spike();
var t = 0;
for (var i = 0; i < 3000000; i++) { var o = { a: i, b: [i] }; t += o.b.length; }
console.log(n + t);
