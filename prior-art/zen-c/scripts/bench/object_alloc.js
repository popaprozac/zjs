// Object literal creation + transitions. Each iteration allocates a
// fresh object with the same shape — the hidden-class transition tree
// should reuse the cached path after the first iteration.
let n = 100000;
let last_sum = 0;
for (let i = 0; i < n; i = i + 1) {
  let o = { a: i, b: i + 1, c: i + 2 };
  last_sum = o.a + o.b + o.c;
}
last_sum
