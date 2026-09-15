var log = [];
log.push(eval('"' + "\u{1F600}" + '"') === "\u{1F600}", eval('"' + "\u{1F600}" + '"').length);
log.push(Function('return "caf' + "é" + '"')().length);
var lone = "\uD800";
log.push(eval("'" + lone + "'") === lone, eval("'" + lone + "'").length);
log.push(eval("var xé = 3; xé * 2"));
log.push(Function("a", "b", "return a + b")(1, 2));
log.join("|");
