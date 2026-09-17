// OPS 1500000 : lookups and short-lived objects against a table of 20,000 records (about 60,000 live cells)
var table = {};
for (var i = 0; i < 20000; i++) { table["k" + i] = { id: i, tags: [i, i + 1] }; }
var t = 0;
for (var i = 0; i < 1500000; i++) { var rec = table["k" + (i % 20000)]; var tmp = { a: rec.id, b: [rec.tags[0]] }; t += tmp.b.length; }
console.log(t);
