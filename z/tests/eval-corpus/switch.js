function classify(v) {
  var out = "";
  switch (v) {
    case 1: out += "one";
    case 2: out += "two"; break;
    case "3": out += "three"; break;
    default: out += "other";
    case 4: out += "four";
  }
  return out;
}
var empty = 0;
switch (5) {}
switch (1) { case 1: empty = 1; }
classify(1) + "|" + classify(2) + "|" + classify("3") + "|" + classify(3) + "|" + classify(4) + "|" + classify() + "|" + empty;
