// OPS 100000 : elements through Promise.all then Promise.race, 20 per round
var rounds = 0;
function round(n) {
  if (n == 0) { console.log(rounds); return; }
  var items = [];
  for (var i = 0; i < 20; i++) { items.push(i % 2 ? i : Promise.resolve(i)); }
  Promise.all(items).then(function (values) { rounds += values.length; return Promise.race(items); }).then(function () { round(n - 1); });
}
round(5000);
