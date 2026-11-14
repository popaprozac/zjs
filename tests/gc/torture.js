// A graph mutated at random while it is checked: old cells given young
// and old ones, links dropped and remade, arrays and objects grown,
// objects turned into dictionaries, strings joined, Maps, Sets, and
// WeakMaps filled and emptied, closures kept and dropped. Every round
// walks what is reachable and prints a checksum, so a cell freed or a
// slot range moved wrongly shows as a different line or a crash. The
// output does not depend on when collections happen: the runner
// compares it across nursery and slice sizes.
var seed = 12345;
function rand(n) { seed = (Math.imul(seed, 1103515245) + 12345) & 0x7fffffff; return seed % n; }
var SIZE = 3000;
var nodes = [];
var weak = new WeakMap();
var byName = new Map();
var tagged = new Set();
var serial = 0;
function makeNode() {
  var id = serial++;
  var node = { id: id, name: "n" + id, next: null, other: null, kids: [], bag: null, fn: null, text: "" };
  if (rand(4) === 0) node.fn = (function (captured) { return function () { return captured.id; }; })(node);
  if (rand(8) === 0) { node.bag = {}; for (var k = 0; k < 40; k++) node.bag["k" + k] = id + k; }
  if (rand(3) === 0) weak.set(node, { of: id, payload: [id, id + 1] });
  if (rand(5) === 0) byName.set(node.name, node);
  if (rand(6) === 0) tagged.add(node);
  return node;
}
for (var i = 0; i < SIZE; i++) nodes.push(makeNode());
function mutate(steps) {
  for (var s = 0; s < steps; s++) {
    var a = nodes[rand(SIZE)], b = nodes[rand(SIZE)];
    switch (rand(12)) {
      case 0: a.next = b; break;
      case 1: a.other = makeNode(); break;
      case 2: a.kids.push(b); if (a.kids.length > 30) a.kids = a.kids.slice(15); break;
      case 3: a.kids.push({ leaf: s, back: a }); break;
      case 4: nodes[rand(SIZE)] = makeNode(); break;
      case 5: a.text = a.text.length > 200 ? "" : a.text + b.name; break;
      case 6: a.next = null; a.other = null; break;
      case 7: if (a.bag === null) a.bag = {}; a.bag["x" + rand(60)] = b; break;
      case 8: if (a.bag !== null) delete a.bag["x" + rand(60)]; break;
      case 9: weak.set(a, { of: a.id, payload: [b] }); break;
      case 10: byName.delete(a.name); tagged.delete(b); if (rand(2) === 0) { byName.set(b.name, b); tagged.add(a); } break;
      default: a.fn = (function (x, y) { return function () { return x.id + y.id; }; })(a, b);
    }
  }
}
function check() {
  var sum = 0, seen = 0;
  for (var i = 0; i < SIZE; i++) {
    var n = nodes[i];
    sum = (sum + n.id * 31 + n.name.length + n.text.length) | 0;
    if (n.next !== null) sum = (sum + n.next.id) | 0;
    if (n.other !== null) sum = (sum + n.other.id * 7 + n.other.name.length) | 0;
    for (var k = 0; k < n.kids.length; k++) { var kid = n.kids[k]; sum = (sum + (kid.leaf !== undefined ? kid.leaf + kid.back.id : kid.id)) | 0; }
    if (n.fn !== null) sum = (sum + n.fn()) | 0;
    if (n.bag !== null) { for (var key in n.bag) { var v = n.bag[key]; sum = (sum + key.length + (typeof v === "number" ? v : v.id)) | 0; } }
    var w = weak.get(n);
    if (w !== undefined) { sum = (sum + w.of + w.payload.length) | 0; var p = w.payload[0]; if (typeof p === "object") sum = (sum + p.id) | 0; seen++; }
  }
  byName.forEach(function (node, name) { sum = (sum + node.id + name.length) | 0; });
  tagged.forEach(function (node) { sum = (sum + node.id) | 0; });
  return sum + " " + seen + " " + byName.size + " " + tagged.size;
}
for (var round = 0; round < 40; round++) {
  mutate(4000);
  console.log(round + ": " + check());
}
