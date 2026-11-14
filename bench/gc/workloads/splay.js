// A splay tree held at 40,000 nodes while keys are inserted and removed:
// every node is touched by rotations long after it was made, and nodes
// die old. The generational hypothesis does not hold here.
var seed = 49734321;
function random() { seed = (Math.imul(seed, 1103515245) + 12345) & 0x7fffffff; return seed; }
function payload(depth, tag) { return depth === 0 ? { array: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], string: "leaf" + tag } : { left: payload(depth - 1, tag), right: payload(depth - 1, tag) }; }
var root = null, size = 0;
function splay(key) {
  if (root === null) return;
  var dummy = { left: null, right: null }, left = dummy, right = dummy, current = root;
  while (true) {
    if (key < current.key) {
      if (current.left === null) break;
      if (key < current.left.key) { var t = current.left; current.left = t.right; t.right = current; current = t; if (current.left === null) break; }
      right.left = current; right = current; current = current.left;
    } else if (key > current.key) {
      if (current.right === null) break;
      if (key > current.right.key) { var u = current.right; current.right = u.left; u.left = current; current = u; if (current.right === null) break; }
      left.right = current; left = current; current = current.right;
    } else break;
  }
  left.right = current.left; right.left = current.right; current.left = dummy.right; current.right = dummy.left; root = current;
}
function insert(key, value) {
  if (root === null) { root = { key: key, value: value, left: null, right: null }; size++; return; }
  splay(key);
  if (root.key === key) return;
  var node = { key: key, value: value, left: null, right: null };
  if (key > root.key) { node.left = root; node.right = root.right; root.right = null; } else { node.right = root; node.left = root.left; root.left = null; }
  root = node; size++;
}
function remove(key) {
  splay(key);
  if (root.key !== key) return;
  if (root.left === null) { root = root.right; } else { var right = root.right; root = root.left; splay(key); root.right = right; }
  size--;
}
function greatestBelow(key) { splay(key); if (root.key < key) return root.key; var n = root.left; if (n === null) return -1; while (n.right !== null) n = n.right; return n.key; }
function insertNew() { var key; do { key = random(); splay(key); } while (root !== null && root.key === key); insert(key, payload(3, key)); return key; }
function run() {
  for (var i = 0; i < 40000; i++) insertNew();
  var sum = 0;
  for (var j = 0; j < 60000; j++) {
    var key = insertNew();
    var below = greatestBelow(key);
    remove(below === -1 ? key : below);
    sum = (sum + (below & 1023)) | 0;
  }
  return sum + size;
}
var result = run();
(typeof console !== "undefined" ? console.log : print)(String(result));
