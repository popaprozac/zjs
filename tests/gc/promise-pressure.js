// Ordinary collections (no gc()) while the promise machinery is inside
// the program's constructors, getters, and callbacks: each of them
// allocates in a loop, so collections land there, and every round checks
// the values that had to survive.
function churn(n) {
  var keep = [];
  for (var i = 0; i < n; i++) { keep.push({ a: i, b: [i, i + 1], c: "s" + i }); }
  return keep.length;
}
class Sub extends Promise {
  constructor(executor) { churn(40); super(function (resolve, reject) { churn(40); executor(resolve, reject); }); }
  static get [Symbol.species]() { churn(40); return Sub; }
}
function Custom(executor) {
  churn(40);
  var self = this;
  executor(function (v) { churn(40); self.value = v; }, function (r) { self.reason = r; });
}
Custom.resolve = function (v) { churn(40); return Sub.resolve(v); };
var bad = 0, rounds = 0;
function check(ok) { if (!ok) bad += 1; }
function round(n) {
  if (n == 0) { console.log(bad == 0 ? "promise rounds intact" : "DAMAGED " + bad, rounds); return; }
  rounds += 1;
  var tag = { n: n, list: [n, n + 1] };
  var thenable = { get then() { churn(40); return function (ok) { ok({ t: n }); }; } };
  var custom = Promise.all.call(Custom, [tag, thenable, Sub.resolve("s" + n)]);
  var parts = Promise.withResolvers.call(Sub);
  Sub.resolve(tag)
    .then(function (v) { churn(40); check(v === tag && v.list[1] == n + 1); return thenable; })
    .finally(function () { churn(40); return Sub.resolve("ignored"); })
    .then(function (v) { check(v.t == n); return Sub.allSettled([parts.promise, Sub.reject("r" + n), v]); })
    .then(function (v) {
      check(v.length == 3 && v[0].value == "p" + n && v[1].reason == "r" + n && v[2].value.t == n);
      check(custom.value && custom.value.length == 3 && custom.value[0] === tag && custom.value[1].t == n && custom.value[2] == "s" + n);
      return Sub.race([new Sub(function () {}), Sub.any([Sub.reject(1), "any" + n])]);
    })
    .then(function (v) { check(v == "any" + n); round(n - 1); });
  parts.resolve("p" + n);
}
round(1500);
