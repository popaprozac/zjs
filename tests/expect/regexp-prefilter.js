// A search may skip the matcher where a match must hold a literal the input
// lacks, try only the starts a literal's place allows, or only the input's
// start for an anchored pattern. Each case is a shape where that reasoning
// could go wrong; the answers are the matcher's own.
var out = [];
function show(m) { return m === null ? "null" : JSON.stringify([m.index].concat(m.slice(0))); }
function all(re, s) {
  var found = [], m;
  re.lastIndex = 0;
  while ((m = re.exec(s)) !== null) {
    found.push(show(m));
    if (m[0] === "") re.lastIndex++;
    if (!re.global && !re.sticky) break;
  }
  out.push(re + " " + JSON.stringify(s) + " -> " + (found.join(" ") || "null"));
}
// Literals: whole, past 32 bytes, leading but failing at the first place.
all(/d1/g, "xd1yd1");
all(/abcdefghijklmnopqrstuvwxyz0123456789ABCDEF/, "abcdefghijklmnopqrstuvwxyz0123456789ABCDEX");
all(/abcdefghijklmnopqrstuvwxyz0123456789ABCDEF/, "--abcdefghijklmnopqrstuvwxyz0123456789ABCDEF");
all(/ab[0-9]/g, "abx ab1 ab ab2");
all(/%\w?$/, "a%b c%d");
// A literal at most one unit after the start, two of whose places overlap.
all(/(^|[^\\])"x/g, '"x \\"x a"x');
all(/[^x]"q/g, 'x"q y"q"q');
// Anchored: only the input's start, whatever lastIndex says.
all(/^ab/g, "abab");
var anchored = /^ab/g; anchored.lastIndex = 1; out.push("anchored at 1: " + show(anchored.exec("abab")));
all(/^ab/m, "x\nab");
// Alternatives, optional repetitions, lookarounds, back references: no
// literal there is required.
all(/abc|xyz/, "--xyz");
all(/a(?:bc){0,3}d/g, "ad abcd abcbcbcd");
all(/a(?!b)c/g, "ac abc");
all(/(?<=x)ab/g, "xab yab");
all(/(?<!x)ab/g, "xab yab");
all(/(a)\1b/, "aab");
all(/\bfoo\b/g, "foobar foo");
// Case-insensitive literals, and the two code points outside ASCII that
// fold to ASCII letters in unicode mode.
all(/TNQP=([^;]*)/i, "tnqp=1; TNQP=2");
all(/##YV19##/gi, "x##yv19## ##Yv19##");
all(/k/iu, "K");
all(/s/iu, "ſ");
all(/ss/iu, "ſſ");
all(/k/i, "K");
all(/K=/iu, "xK=");
// Sixteen-bit input: a literal's place in units, surrogate pairs.
all(/(^|[^\\])"x/g, '€"x \\"x €a"x');
all(/^./u, "😀");
var pair = /^./gu; pair.lastIndex = 1; out.push("pair at 1: " + show(pair.exec("😀")));
var inside = /\uDE00/g; inside.lastIndex = 1; out.push("half at 1: " + show(inside.exec("😀")));
all(/.x/gu, "😀x");
// Sticky patterns try their one place.
all(/ab/y, "xab");
var sticky = /ab/y; sticky.lastIndex = 1; out.push("sticky at 1: " + show(sticky.exec("xab")));
// replace, split, match, search over the same shapes.
out.push("x1d1".replace(/d1/g, "<$&>") + " " + JSON.stringify("a1b1c".split(/1/)) + " " + JSON.stringify("ab1ab2".match(/ab\d/g)) + " " + "zzab".search(/ab/));
// A small sweep: random patterns, flags, subjects, and starts. Its hash is
// the matcher's answers without the facts.
var seed = 7;
function rnd(n) { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; }
function pick(a) { return a[rnd(a.length)]; }
var atoms = ["a", "b", "ab", "d1", "=", ".", "[ab]", "\\w", "^", "$", "(a)", "(ab|c)", "a*", "(?:ab){0,2}", "(?!b)", "(?<=a)", "(a)\\1", "k", "s", "\\u212A", "(^|[^\\\\])", "\"", "[0-9]+"];
var alphabet = ["a", "b", "d", "1", "=", " ", "\"", "\\", "ab", "d1", "k", "K", "s", "K", "ſ", "é", "😀"];
var flagSets = ["", "g", "i", "m", "y", "gi", "u", "iu", "gu"];
var hash = 0;
for (var t = 0; t < 600; t++) {
  var source = "", n = 1 + rnd(4);
  for (var i = 0; i < n; i++) source += pick(atoms);
  var re;
  try { re = new RegExp(source, pick(flagSets)); } catch (e) { continue; }
  for (var k = 0; k < 4; k++) {
    var s = "", length = rnd(10);
    for (var j = 0; j < length; j++) s += pick(alphabet);
    for (var start = 0; start <= s.length; start += 1 + rnd(2)) {
      re.lastIndex = start;
      var text = show(re.exec(s)) + re.lastIndex;
      for (var c = 0; c < text.length; c++) hash = (hash * 31 + text.charCodeAt(c)) | 0;
    }
  }
}
out.push("sweep " + hash);
console.log(out.join("\n"));
