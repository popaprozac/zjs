// Closure-over-captured-local invocation. Measures the env-object
// closure model — every read/write of `count` inside the closure goes
// through LoadProp/StoreProp against the env, IC-cached.
function make() {
  let count = 0;
  return function () { count = count + 1; return count };
}
let inc = make();
let n = 200000;
let last = 0;
for (let i = 0; i < n; i = i + 1) {
  last = inc();
}
last
