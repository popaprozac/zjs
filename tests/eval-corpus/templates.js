var name = "z";
var n = 2;
var plain = `no subs`;
var mixed = `${name}-${n + 1}-${"str"}-${n > 1 ? `nested ${name}` : "no"}`;
var leading = `${n}${n}` + `end`;
var escapes = `tab\tnew\\n${n}`;
plain + "|" + mixed + "|" + leading + "|" + escapes + "|" + `` + "|" + `${undefined}${null}${true}`;
