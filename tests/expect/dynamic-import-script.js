// import() from a script resolves against the script's own path and
// gives the namespace once the module has run; a module that cannot be
// found rejects.
console.log("before");
import("./modules/tla-later.mjs")
  .then((ns) => console.log("loaded", ns.value))
  .then(() => import("./modules/missing.mjs"))
  .catch((e) => console.log("missing rejects", e instanceof Error));
console.log("after");
