// Collections inside async bodies: allocation pressure during an async
// function's first run and after an await, inside a suspended async
// generator, and inside an async delegation. The generator and its
// record are reachable only through the frame or the pending promise
// reaction while these run.
var out = [];
function churn() { var junk = []; for (var i = 0; i < 200000; i++) { junk.push({ i: i }); if (i % 40000 === 0) junk = []; } }
async function fn() { churn(); var a = await Promise.resolve("a"); churn(); var b = await Promise.resolve("b"); return a + b; }
async function* agen() { churn(); yield "y1"; churn(); yield "y2"; }
var iter = { [Symbol.asyncIterator]() { return this; }, i: 0, next(v) { churn(); this.i++; return { value: "d" + this.i + (v || ""), done: this.i > 2 }; } };
async function* delegating() { var v = yield* iter; churn(); yield "end:" + v; }
async function main() {
  out.push(await fn());
  var g = agen(); out.push((await g.next()).value); churn(); out.push((await g.next()).value);
  var d = delegating(); out.push((await d.next()).value); churn(); out.push((await d.next("x")).value); out.push((await d.next("y")).value);
  console.log(out.join(","));
}
main();
