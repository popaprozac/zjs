// How many microtask turns each promise form takes, read off an
// interleaved trace against two tickers: the engine adds no turn the
// specification does not have, and drops none.
var log = [];
function ticker(name, n) { var p = Promise.resolve(); for (let i = 1; i <= n; i++) { p = p.then(function () { log.push(name + i); }); } }
ticker("t", 8);
class Sub extends Promise {}
var native = Promise.resolve("n"), sub = Sub.resolve("s"), thenable = { then: function (ok) { ok("th"); } };
(async function () { await native; log.push("await native"); })();
(async function () { await sub; log.push("await sub"); })();
(async function () { await thenable; log.push("await thenable"); })();
(async function () { await 1; log.push("await value"); })();
(async function () { return native; })().then(function () { log.push("async return native"); });
Promise.resolve(native).then(function () { log.push("resolve(native).then"); });
Sub.resolve(native).then(function () { log.push("Sub.resolve(native).then"); });
new Promise(function (r) { r(native); }).then(function () { log.push("new resolved with native"); });
native.finally(function () {}).then(function () { log.push("finally.then"); });
sub.finally(function () {}).then(function () { log.push("sub finally.then"); });
Promise.all([native, sub, 3]).then(function () { log.push("all"); });
Sub.all([native, sub, 3]).then(function () { log.push("Sub.all"); });
Promise.race([native]).then(function () { log.push("race"); });
Promise.allSettled([native]).then(function () { log.push("allSettled"); });
Promise.any([native]).then(function () { log.push("any"); });
(async function* () { yield native; yield sub; })().next().then(function () { log.push("agen yield native"); });
ticker("u", 1);
Promise.resolve().then(function () {}).then(function () {}).then(function () {}).then(function () {}).then(function () {}).then(function () {}).then(function () {}).then(function () {}).then(function () {}).then(function () { console.log(log.join("\n")); });
