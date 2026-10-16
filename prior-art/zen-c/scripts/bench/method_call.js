// Method dispatch on a prototype. Tests Op::MethodInvoke + prototype-
// chain lookup + this-binding for user methods.
class Counter {
  constructor() { this.n = 0; }
  inc() { this.n = this.n + 1; return this.n; }
}
let c = new Counter();
let n = 200000;
let last = 0;
for (let i = 0; i < n; i = i + 1) {
  last = c.inc();
}
last
