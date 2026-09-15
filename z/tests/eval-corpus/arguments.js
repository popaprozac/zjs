var log = [];
function count() { return arguments.length; }
function second() { return arguments[1]; }
function all() { var s = ""; for (var i = 0; i < arguments.length; i++) s += arguments[i] + ","; return s; }
function shadowed(arguments) { return arguments; }
function nested() { function inner() { return arguments.length; } return inner(1, 2, 3, 4); }
function tagged() { return Object.prototype.toString.call(arguments); }
function isArr() { return Array.isArray(arguments); }
function withParams(a, b) { return a + ":" + b + ":" + arguments.length + ":" + arguments[2]; }
log.push(count(), count(1, 2, 3), second("a", "b"), all(1, "two", true), shadowed(7), nested(), tagged(), isArr(), withParams(1, 2, 3, 4), withParams(1));
function rest(first, ...others) { return first + "|" + others.length + "|" + others.join("+"); }
function onlyRest(...items) { return items.length + ":" + Array.isArray(items); }
log.push(rest(1, 2, 3, 4), rest(1), onlyRest(), onlyRest("x", "y"));
var caught = "";
try { arguments; } catch (e) { caught = e.name; }
log.push(caught);
log.join("|");
