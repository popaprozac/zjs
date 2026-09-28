// A throw while an async function evaluates its parameters rejects the
// promise its call returns, whatever made the call; the caller carries
// on. Generators and async generators still throw at the call.
function report(label, call) {
  try {
    const p = call();
    console.log(label, "returned a promise:", p instanceof Promise);
    p.then(() => console.log(label, "fulfilled"), (e) => console.log(label, "rejected", e.name));
  } catch (e) {
    console.log(label, "threw", e.name);
  }
}

async function plain(p = null.x) {}
report("plain", () => plain());
report("arrow", () => (async (q = undefinedName) => q)());
const holder = { async method({ a }) { return a; } };
report("pattern", () => holder.method());
class Holder { static async fails(v = (() => { throw new RangeError("r"); })()) {} }
report("static", () => Holder.fails());
report("call", () => plain.call(null));
report("from a builtin", () => [1].map(async function (v, i, all, extra = null.y) {})[0]);
report("eval", () => (async function (p = eval("var arguments = 1"), arguments) {})());
async function fine(p = 1) { return p; }
report("fine", () => fine());
async function body() { null.z; }
report("body", () => body());

function* generator(p = null.x) {}
report("generator", () => generator());
async function* asyncGenerator(p = null.x) {}
report("async generator", () => asyncGenerator());

function inTry() {
  try {
    const p = plain();
    p.catch(() => {});
    return "not caught here";
  } catch (e) {
    return "caught " + e.name;
  }
}
console.log(inTry());
(async () => {
  try { await plain(); } catch (e) { console.log("awaited", e.name); }
})();
