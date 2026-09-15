var log = [];
var closed = 0;
function make() { return { [Symbol.iterator]: function () { return { next: function () { return { value: 1, done: false }; }, return: function () { closed++; return {}; } }; } }; }
try { for (var a of make()) { throw new Error("body"); } } catch (e) { log.push(e.message); }
try { for (var b of make()) { null.x; } } catch (e) { log.push(e.name); }
var loud = { [Symbol.iterator]: function () { return { next: function () { return { value: 1, done: false }; }, return: function () { closed++; throw new Error("from return"); } }; } };
try { for (var c of loud) { throw new Error("original"); } } catch (e) { log.push(e.message); }
try { for (var d of loud) { break; } } catch (e) { log.push("break:" + e.message); }
function nestedTry() {
  for (var e of make()) {
    try { return "returned"; } finally { closed++; }
  }
}
log.push(nestedTry());
var after = "";
for (var f of [1, 2, 3]) {
  try { if (f == 2) break; after += f; } catch (err) { after += "!"; }
}
try { throw new Error("late"); } catch (e) { after += e.message; }
log.push(after);
var count = 0;
outer: for (var g of [1, 2]) { for (var h of make()) { try { count++; continue outer; } finally { count += 10; } } }
log.push(count, closed);
log.join("|");
