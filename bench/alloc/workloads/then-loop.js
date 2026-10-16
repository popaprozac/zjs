// OPS 200000 : new Promise + then, one at a time (small live set)
var done = 0;
function step(n) { if (n == 0) { console.log(done); return; } new Promise(function (resolve) { resolve(n); }).then(function () { done += 1; step(n - 1); }); }
step(200000);
