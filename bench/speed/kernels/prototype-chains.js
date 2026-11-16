// Names found past an object's first prototype, or nowhere: a base
// class's method called on a subclass's object, a method two classes
// up, `hasOwnProperty` on an instance, and options an object does not
// have. The work runs in a function, as most code does.
function run() {
  class Base { constructor(v) { this.v = v; } value() { return this.v; } }
  class Mid extends Base { twice() { return this.v * 2; } }
  class Leaf extends Mid { own() { return 1; } }
  var leaf = new Leaf(3), mid = new Mid(2);
  var options = { size: 4 }, defaults = { size: 1, limit: 9 };
  var total = 0;
  for (var i = 0; i < 300000; i++) {
    total = (total + leaf.value() + mid.value() + leaf.twice()) | 0;
    if (mid.hasOwnProperty("v")) total = (total + 1) | 0;
    var chosen = i & 1 ? options : defaults;
    total = (total + (chosen.limit === undefined ? chosen.size : chosen.limit)) | 0;
    if (options.verbose) total = (total - 1) | 0;
  }
  return total;
}
var result = run();
