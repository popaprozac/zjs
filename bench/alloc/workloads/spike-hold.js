// OPS 3000000 : the spike workload, then a long arithmetic loop so the address space can be inspected while it runs
function spike() { var held = []; for (var i = 0; i < 2000000; i++) { held.push({ id: i, pair: [i, i] }); } return held.length; }
var n = spike();
var t = 0;
for (var i = 0; i < 3000000; i++) { var o = { a: i, b: [i] }; t += o.b.length; }
console.log(n + t);
// Stay alive doing nothing the collector cares about, so the address space can be inspected.
var spin = 0; for (var k = 0; k < 900000000; k++) { spin = (spin + k) | 0; }
console.log(spin);
