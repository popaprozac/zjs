// JSON.stringify and JSON.parse round trips of a nested record.
var record = { name: "widget", tags: ["a", "b", "c"], dims: { w: 12.5, h: 3, d: 7 }, items: [] };
for (var i = 0; i < 50; i++) record.items.push({ id: i, label: "part-" + i, ok: i % 2 === 0 });
var total = 0;
for (var round = 0; round < 1500; round++) {
  var text = JSON.stringify(record);
  var back = JSON.parse(text);
  total = (total + text.length + back.items[round % 50].id) | 0;
}
var result = total;
