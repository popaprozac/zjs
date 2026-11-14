// Trees built and dropped at several depths beside one long-lived tree:
// tracing and promotion of linked structures (the classic GC benchmark).
function make(depth) { return depth === 0 ? { left: null, right: null } : { left: make(depth - 1), right: make(depth - 1) }; }
function check(node) { return node.left === null ? 1 : 1 + check(node.left) + check(node.right); }
function run() {
  var maxDepth = 15, total = 0;
  var longLived = make(maxDepth);
  for (var depth = 4; depth <= maxDepth; depth += 2) {
    var iterations = 1 << (maxDepth - depth + 3);
    for (var i = 0; i < iterations; i++) total = (total + check(make(depth))) | 0;
  }
  return total + check(longLived);
}
var result = run();
(typeof console !== "undefined" ? console.log : print)(String(result));
