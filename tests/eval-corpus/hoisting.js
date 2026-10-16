var before = declared(2);
function declared(x) { return x * 21; }
var chain = first();
function first() { return second() + 1; }
function second() { return 41; }
"" + before + "," + chain + "," + typeof_free;
var typeof_free = "done";
