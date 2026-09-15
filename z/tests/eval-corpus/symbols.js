var log = [];
var s = Symbol("tag");
var anon = Symbol();
log.push(typeof s, s.toString(), String(s), s.description, anon.description, String(anon), Symbol("x") === Symbol("x"), Symbol.for("k") === Symbol.for("k"), Symbol.keyFor(Symbol.for("k")), Symbol.keyFor(s), typeof Symbol.iterator, Symbol.iterator.toString());
var o = { a: 1 };
o[s] = "hidden";
log.push(o[s], Object.keys(o).join(), Object.getOwnPropertyNames(o).join(), Object.getOwnPropertySymbols(o).length, Object.getOwnPropertySymbols(o)[0] === s, s in o, o.hasOwnProperty(s));
var count = 0;
for (var k in o) count++;
delete o[s];
log.push(count, o[s], Object.getOwnPropertySymbols(o).length);
var tagged = { get [Symbol.toStringTag]() { return "Custom"; } };
var prim = { [Symbol.toPrimitive]: function (hint) { return hint === "number" ? 42 : "str:" + hint; } };
log.push(Object.prototype.toString.call(tagged), Object.prototype.toString.call(s), prim + "", `${prim}`, String(prim));
function Even() {}
Object.defineProperty(Even, Symbol.hasInstance, { value: function (v) { return v % 2 === 0; } });
log.push(2 instanceof Even, 3 instanceof Even, [] instanceof Array);
var caught = [];
try { new Symbol(); } catch (e) { caught.push(e.name); }
try { s + ""; } catch (e) { caught.push(e.name); }
try { s * 1; } catch (e) { caught.push(e.name); }
try { `${s}`; } catch (e) { caught.push(e.name); }
try { Symbol.keyFor("k"); } catch (e) { caught.push(e.name); }
try { Symbol.prototype.toString.call(1); } catch (e) { caught.push(e.name); }
log.push(caught.join(), Object(s).valueOf() === s, Symbol.prototype[Symbol.toStringTag], s.constructor === Symbol, Symbol.length, Symbol.name);
log.join("|");
