// Property reads at one site across four object shapes.
var shapes = [];
for (var i = 0; i < 1000; i++) {
  var k = i % 4;
  if (k === 0) shapes.push({ v: i });
  else if (k === 1) shapes.push({ a: 1, v: i });
  else if (k === 2) shapes.push({ a: 1, b: 2, v: i });
  else shapes.push({ a: 1, b: 2, c: 3, v: i });
}
var total = 0;
for (var round = 0; round < 1200; round++) {
  for (var j = 0; j < shapes.length; j++) total = (total + shapes[j].v) | 0;
}
var result = total;
