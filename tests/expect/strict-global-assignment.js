"use strict";
// Strict code cannot create a global by assigning to a name nothing
// declares: every form of assignment throws a ReferenceError, after the
// right-hand side ran, and creates nothing. A property of the global
// object declares the name; a read-only global throws a TypeError.
function attempt(label, f) {
  try {
    f();
    console.log(label, "stored");
  } catch (e) {
    console.log(label, e.name);
  }
}
attempt("plain", () => { undeclared1 = 1; });
attempt("compound", () => { undeclared2 += 1; });
attempt("logical", () => { undeclared3 ||= 1; });
attempt("update", () => { undeclared4++; });
attempt("array pattern", () => { [undeclared5] = [1]; });
attempt("object pattern", () => { ({ a: undeclared6 } = { a: 1 }); });
attempt("for-in head", () => { for (undeclared7 in { k: 1 }) {} });
attempt("for-of head", () => { for (undeclared8 of [1]) {} });
attempt("class method", () => { class C { m() { undeclared9 = 1; } } new C().m(); });
attempt("eval code", () => { eval("undeclared10 = 1"); });
let ran = false;
attempt("right side first", () => { undeclared11 = (ran = true); });
console.log("right side ran:", ran, "created:", typeof undeclared1, typeof undeclared11);

globalThis.onGlobalObject = 0;
attempt("global object property", () => { onGlobalObject = 5; });
console.log(onGlobalObject, globalThis.onGlobalObject);
attempt("read-only global", () => { Infinity = 1; });
console.log(Infinity);

// Sloppy code, eval code included, still creates the global.
const sloppy = Function("createdBySloppy = 1; eval('createdBySloppyEval = 2'); return createdBySloppy + createdBySloppyEval;");
console.log(sloppy(), typeof createdBySloppy, typeof createdBySloppyEval);
