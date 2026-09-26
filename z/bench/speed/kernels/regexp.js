// Regular expression matching over a log-like text.
var lines = [];
for (var i = 0; i < 400; i++) lines.push("2026-09-" + (10 + i % 20) + " host" + (i % 7) + " GET /api/v" + (i % 3) + "/items/" + i + " 200 " + (i * 13 % 997) + "ms");
var text = lines.join("\n");
var pattern = /host(\d) GET \/api\/v(\d)\/items\/(\d+) (\d{3}) (\d+)ms/g;
var total = 0;
for (var round = 0; round < 60; round++) {
  pattern.lastIndex = 0;
  var m;
  while ((m = pattern.exec(text)) !== null) total = (total + Number(m[3]) + Number(m[5])) | 0;
  total = (total + text.replace(/\d+ms/g, "x").length) | 0;
}
var result = total;
