// Promises, generator objects, and iterator results are ordinary objects
// to a program whatever the engine keeps in them: their own keys show
// only what the program put there, and they go on working after the
// program freezes them, gives them many properties, or deletes one.
var log = [];
function note() { log.push(Array.prototype.join.call(arguments, " ")); }
function describe(object) {
  return [Object.keys(object).join(), Object.getOwnPropertyNames(object).join(), Reflect.ownKeys(object).length,
    Object.getOwnPropertySymbols(object).length, JSON.stringify(object)].join(" | ");
}
function crowd(object, count) { for (var i = 0; i < count; i++) object["p" + i] = i; return object; }
function sum(object, count) { var total = 0; for (var i = 0; i < count; i++) total += object["p" + i]; return total; }

// --- a promise's own keys ---
var bare = Promise.resolve(1);
note("fresh promise:", describe(bare));
bare.extra = "x";
note("with a property:", describe(bare), Object.getOwnPropertyDescriptor(bare, "extra").writable);
var names = [];
for (var name in bare) names.push(name);
note("for-in:", names.join(), "| assign:", JSON.stringify(Object.assign({}, bare)), "| spread:", JSON.stringify({ ...bare }));

// --- many properties, then one deleted from the middle ---
var settleCrowded;
var crowded = crowd(new Promise(function (resolve) { settleCrowded = resolve; }), 200);
crowded.then(function (v) { note("crowded pending promise settled:", v, sum(crowded, 200), Object.keys(crowded).length); });
settleCrowded("late");
var crowdedSettled = crowd(Promise.resolve("early"), 200);
crowdedSettled.then(function (v) { note("crowded settled promise:", v, sum(crowdedSettled, 200)); });
var holed = Promise.reject(new RangeError("holed"));
holed.a = 1; holed.b = 2; holed.c = 3;
delete holed.a;
note("after a delete:", describe(holed));
holed.then(null, function (e) { note("promise that lost a property rejected:", e.message, holed.b + holed.c); });
holed.d = 4;
holed.catch(function (e) { note("and again after another add:", e.constructor.name, Object.keys(holed).join()); });
var settleHoled;
var holedPending = new Promise(function (resolve) { settleHoled = resolve; });
holedPending.x = 1; holedPending.y = 2; delete holedPending.x;
holedPending.then(function (v) { return v + 1; }).then(function (v) { note("pending promise that lost a property:", v); });
holedPending.then(function (v) { note("its second reaction:", v); });
holedPending.finally(function () { note("its third:", Object.keys(holedPending).join()); });
settleHoled(41);

// --- frozen, sealed, non-extensible ---
var frozen = Object.freeze(new Promise(function (resolve) { resolve("frozen value"); }));
note("frozen:", Object.isFrozen(frozen), describe(frozen));
frozen.then(function (v) { note("frozen promise settled:", v); });
var settleFrozen;
var frozenPending = Object.freeze(new Promise(function (resolve) { settleFrozen = resolve; }));
frozenPending.then(function (v) { note("frozen pending promise settled:", v, Object.isFrozen(frozenPending)); });
settleFrozen("after freeze");
var sealed = Object.seal(crowd(Promise.resolve("sealed value"), 3));
sealed.p0 = 10;
sealed.then(function (v) { note("sealed:", v, Object.isSealed(sealed), sealed.p0); });
var closed = Object.preventExtensions(Promise.resolve("closed value"));
closed.added = 1;
closed.then(function (v) { note("non-extensible:", v, Object.isExtensible(closed), "added" in closed); });

// --- subclasses with fields ---
class Tagged extends Promise {
  constructor(executor) { super(executor); this.tag = "t"; this.count = 0; }
}
var tagged = Tagged.resolve(5);
note("subclass instance:", describe(tagged));
var derived = tagged.then(function (v) { return v * 2; });
note("derived:", derived instanceof Tagged, derived.tag, Object.keys(derived).join());
derived.then(function (v) { note("subclass chain:", v); });
(async function () { note("awaited promise with properties:", await crowd(Promise.resolve("w"), 50)); })();
(async function () { try { await holed; } catch (e) { note("awaited promise that lost a property:", e.message); } })();

// --- generator objects ---
function* count() { var got = yield 1; yield got; return "end"; }
var gen = count();
note("fresh generator:", describe(gen));
gen.label = "g";
crowd(gen, 200);
note("crowded generator:", JSON.stringify(gen.next()), JSON.stringify(gen.next("sent")), sum(gen, 200));
delete gen.p7;
note("after a delete:", JSON.stringify(gen.next()), JSON.stringify(gen.next()), Object.keys(gen).length, gen.label);
var frozenGen = Object.freeze(count());
note("frozen generator:", JSON.stringify(frozenGen.next()), JSON.stringify(frozenGen.return("r")), JSON.stringify(frozenGen.next()));
var holedGen = count();
holedGen.a = 1; holedGen.b = 2; delete holedGen.a;
note("generator that lost a property:", JSON.stringify(holedGen.next()), [...holedGen].join(), Object.keys(holedGen).join());
async function* ticks() { yield "a"; yield "b"; }
var asyncGen = crowd(ticks(), 100);
delete asyncGen.p3;
(async function () {
  var seen = [];
  for await (var tick of asyncGen) seen.push(tick);
  note("async generator with properties:", seen.join(), Object.keys(asyncGen).length);
})();
async function plain() { return "async result"; }
var asyncResult = plain();
note("async function's promise:", describe(asyncResult), asyncResult instanceof Promise);

// --- iterator results ---
var result = count().next();
note("iterator result:", Object.keys(result).join(), JSON.stringify(Object.getOwnPropertyDescriptors(result)));
result.extra = 1;
delete result.value;
note("changed:", JSON.stringify(result), "value" in result, Object.keys(result).join());
var arrayResult = [7][Symbol.iterator]().next();
note("array iterator result:", JSON.stringify(arrayResult), Object.getPrototypeOf(arrayResult) === Object.prototype);
var doneResult = count().return("x");
note("return result:", JSON.stringify(doneResult), Object.isExtensible(doneResult), Object.isFrozen(doneResult));
ticks().next().then(function (r) { note("async iterator result:", JSON.stringify(r), Object.keys(r).join()); });

function settle(n, done) { if (n == 0) { done(); } else { Promise.resolve().then(function () { settle(n - 1, done); }); } }
settle(12, function () { console.log(log.join("\n")); });
