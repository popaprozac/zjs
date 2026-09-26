// Building, scanning, splitting, and joining strings.
// The work runs in a function, as most code does.
function run() {
  var total = 0;
  for (var round = 0; round < 200; round++) {
    var s = "";
    for (var i = 0; i < 500; i++) s += "item" + i + ",";
    for (var j = 0; j < s.length; j += 7) total = (total + s.charCodeAt(j)) | 0;
    var parts = s.split(",");
    total = (total + parts.length + parts.join("|").indexOf("item499")) | 0;
    total = (total + s.slice(10, 50).toUpperCase().length) | 0;
  }
  return total;
}
var result = run();
