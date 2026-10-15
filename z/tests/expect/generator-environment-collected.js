// A suspended generator keeps its environment through collections even
// when no closure that captured it is still alive: the closure here is
// called once and dropped, and the churn between steps reuses freed cells.
function* counter() {
  let n = 0;
  (() => { n = n + 1; })();
  let a = 1, b = 2, c = 3, d = 4;
  while (true) {
    yield n + a + b + c + d;
    n = n + 10;
  }
}
function* guarded() {
  let seen = 0;
  (() => { seen = seen + 1; })();
  try {
    while (true) {
      yield seen;
      seen = seen + 1;
    }
  } catch (error) {
    yield "caught " + error + " after " + seen;
  }
}
const g = counter();
const h = guarded();
const out = [];
for (let k = 0; k < 6; k++) {
  out.push(g.next().value, h.next().value);
  for (let r = 0; r < 3; r++) {
    gc();
    for (let i = 0; i < 30000; i++) ({ k: i, s: [i] });
  }
}
out.push(h.throw("stop").value);
console.log(out.join(","));
