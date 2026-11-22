// A class's static block runs as a plain function on the class, once,
// while the class is defined: what it throws, the definition throws.
function show(label, f) { try { console.log(label, f()); } catch (e) { console.log(label, "threw", (e && e.name) || e); } }
show("throw", function () { class C { static { throw new RangeError("from the block"); } } return "defined"; });
show("throw from a call", function () { function fail() { throw new TypeError("deep"); } class C { static { fail(); } } return "defined"; });
show("missing method", function () { class C { static { this.missing(); } } return "defined"; });
show("class expression", function () { var seen = "unset"; try { seen = class { static { throw new SyntaxError("expr"); } }; } catch (e) { return e.name + "," + seen; } });
show("stops the rest", function () { var log = []; try { class C { static { log.push("a"); throw 1; } static { log.push("b"); } } } catch (e) { log.push("caught " + e); } return log.join(); });
show("order", function () { var log = []; class C { static { log.push("first"); } static x = log.push("field"); static { log.push("last"); } } log.push("after"); return log.join(); });
show("this and var", function () { class C { static { var kept = this; C.same = kept === C; C.arrow = (() => this)() === C; } } return [C.same, C.arrow, typeof kept].join(); });
show("try inside", function () { class C { static { try { throw new Error("in"); } catch (e) { C.caught = e.message; } finally { C.done = true; } } } return [C.caught, C.done].join(); });
