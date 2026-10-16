// `"a" + x + "b"`, `s += "a" + x`, and template literals join their pieces
// in one string; conversions keep their order and hints.
var out = [];
function show(v) { out.push(typeof v === "string" ? v : String(v)); }
var log = [];
function tracked(name, value) { return { valueOf: function () { log.push(name + ".valueOf"); return value; }, toString: function () { log.push(name + ".toString"); return "T" + name; } }; }

function chains() {
  var n = 7, d = 2.5, t = true, z = null, u, neg = -0, big = 12345678901;
  show("a" + n + "b" + d + "c" + t + "d" + z + "e" + u + "f" + neg + "g" + big);
  var p = tracked("p", 1), q = tracked("q", "Q");
  log = [];
  show("x" + p + "-" + q + "!");
  show(log.join(","));
  var arr = [1, 2];
  show("arr:" + arr + ";" + arr.length);
  var sym = Symbol("s");
  try { show("s" + sym + "!"); } catch (e) { show(e.constructor.name); }
}
chains();

function accumulate() {
  var s = "";
  for (var i = 0; i < 5; i++) s += "item" + i + ",";
  show(s);
  var num = 5;
  num += "a" + 1 + "b";
  show(num);
  var o = tracked("acc", 10), x = tracked("x", 2);
  log = [];
  o += "k" + x + "!";
  show(o);
  show(log.join(","));
  var w = "start";
  w = w + "é" + 1 + "✓";
  show(w + ":" + w.length);
  var long = "L".repeat(300);
  var joined = "<" + long + ">" + 3;
  show(joined.length + " " + joined.slice(0, 3) + joined.slice(-3));
  var t = "t";
  t = t + "" + "" + "";
  show(t);
}
accumulate();

function captured() {
  var s = "c";
  var add = function (k) { s += "-" + k + "."; return s; };
  add(1); add(2);
  return s;
}
show(captured());

function templates() {
  var o = { valueOf: function () { return 1; }, toString: function () { return "str"; } };
  show(`a${o}b`);
  log = [];
  function f(name, value) { log.push("eval " + name); return tracked(name, value); }
  show(`[${f("m", 1)}|${f("n", 2)}]`);
  show(log.join(","));
  show(`${1}${2}${"3"}`);
  show(`outer ${`inner ${1 + 1}`} end`);
  show(`${"✓"}-${"é"}`);
  try { show(`${Symbol("t")}`); } catch (e) { show(e.constructor.name); }
  var many = `${0}${1}${2}${3}${4}${5}${6}${7}${8}${9}`;
  show(many);
}
templates();
console.log(out.join("\n"));
