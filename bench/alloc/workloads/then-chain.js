// OPS 200000 : then-links built on a pending chain, then drained (the chain is live throughout)
var p = Promise.resolve(0);
for (var i = 0; i < 200000; i++) { p = p.then(function (x) { return x + 1; }); }
p.then(function (v) { console.log(v); });
