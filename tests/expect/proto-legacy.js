// Annex B: __proto__ in object literals and on Object.prototype, and the
// legacy accessor functions. Only outcomes are printed, never messages.
var log = [];
function kind(f) { try { f(); return "ok"; } catch (e) { return e.constructor.name; } }
var base = { tag: "base" };
var a = { __proto__: base, own: 1 };
log.push("literal proto: " + (Object.getPrototypeOf(a) === base) + " own keys " + Object.keys(a).join(","));
log.push("literal string key: " + (Object.getPrototypeOf({ "__proto__": base }) === base));
log.push("literal null: " + (Object.getPrototypeOf({ __proto__: null }) === null));
var ignored = { __proto__: 7 };
log.push("literal non-object ignored: " + (Object.getPrototypeOf(ignored) === Object.prototype) + " own " + ignored.hasOwnProperty("__proto__"));
var computed = { ["__proto__"]: base };
log.push("computed is own: " + computed.hasOwnProperty("__proto__") + " " + (Object.getPrototypeOf(computed) === Object.prototype));
var __proto__ = base;
var shorthand = { __proto__ };
log.push("shorthand is own: " + shorthand.hasOwnProperty("__proto__"));
var method = { __proto__() { return 1; } };
log.push("method is own: " + method.hasOwnProperty("__proto__") + " " + (Object.getPrototypeOf(method) === Object.prototype));
var fn = { __proto__: function () {} };
log.push("proto function unnamed: " + (Object.getPrototypeOf(fn).name === ""));
log.push("duplicate: " + kind(function () { eval("({ __proto__: null, __proto__: null })"); }));
log.push("duplicate with computed: " + kind(function () { eval("({ __proto__: null, ['__proto__']: null })"); }));
log.push("permitted in pattern: " + kind(function () { var x, y; eval("({ __proto__: x, __proto__: y } = { __proto__: null });"); }));

var d = Object.getOwnPropertyDescriptor(Object.prototype, "__proto__");
log.push("accessor: " + (typeof d.get) + "/" + (typeof d.set) + " enumerable " + d.enumerable + " configurable " + d.configurable + " names " + d.get.name + "|" + d.set.name + " lengths " + d.get.length + "|" + d.set.length);
log.push("get on object: " + (a.__proto__ === base) + " on primitive: " + (d.get.call(1) === Number.prototype) + " on null: " + kind(function () { d.get.call(null); }));
var target = {};
target.__proto__ = base;
log.push("set on object: " + (Object.getPrototypeOf(target) === base));
target.__proto__ = 5;
log.push("set non-object ignored: " + (Object.getPrototypeOf(target) === base));
log.push("set on primitive: " + kind(function () { d.set.call(1, base); }) + " on undefined: " + kind(function () { d.set.call(undefined, base); }));
log.push("set cycle: " + kind(function () { base.__proto__ = a; }));
log.push("set immutable: " + kind(function () { Object.prototype.__proto__ = {}; }) + " " + kind(function () { Object.prototype.__proto__ = null; }));
log.push("set sealed: " + kind(function () { Object.preventExtensions(target); target.__proto__ = {}; }));

var o = { plain: 1 };
o.__defineGetter__("g", function () { return 42; });
o.__defineSetter__("s", function (v) { this.stored = v; });
o.s = 9;
var gd = Object.getOwnPropertyDescriptor(o, "g");
log.push("defineGetter: " + o.g + " enumerable " + gd.enumerable + " configurable " + gd.configurable + " setter " + (gd.set === undefined));
log.push("defineSetter: " + o.stored + " getter " + (Object.getOwnPropertyDescriptor(o, "s").get === undefined));
o.__defineSetter__("g", function () {});
log.push("define keeps other side: " + (o.g === 42) + " " + (typeof Object.getOwnPropertyDescriptor(o, "g").set));
o.__defineGetter__("plain", function () { return "now accessor"; });
log.push("define over data: " + o.plain);
log.push("define non-callable: " + kind(function () { o.__defineGetter__("x", 1); }) + " " + kind(function () { o.__defineSetter__("x", {}); }));
Object.defineProperty(o, "fixed", { value: 1, configurable: false });
log.push("define non-configurable: " + kind(function () { o.__defineGetter__("fixed", function () {}); }));
log.push("define on null: " + kind(function () { Object.prototype.__defineGetter__.call(null, "x", function () {}); }));
var keyCalls = 0;
var keyObj = { toString: function () { keyCalls++; return "k"; } };
o.__defineGetter__(keyObj, function () { return "by object key"; });
log.push("key converted once: " + keyCalls + " " + o.k);
log.push("define key abrupt: " + kind(function () { o.__defineGetter__({ toString: function () { throw new RangeError("no"); } }, function () {}); }));
var sym = Symbol("s");
o.__defineGetter__(sym, function () { return "sym"; });
log.push("symbol key: " + o[sym] + " " + (o.__lookupGetter__(sym) !== undefined));

var child = Object.create(o);
log.push("lookupGetter own: " + (o.__lookupGetter__("g")() === 42) + " through proto: " + (child.__lookupGetter__("g")() === 42));
log.push("lookupSetter: " + (typeof o.__lookupSetter__("s")) + " " + (o.__lookupSetter__("plain") === undefined));
log.push("lookup data property stops: " + (child.__lookupGetter__("stored") === undefined));
Object.defineProperty(child, "g", { value: "shadow", configurable: true });
log.push("lookup shadowed by data: " + (child.__lookupGetter__("g") === undefined));
log.push("lookup absent: " + (o.__lookupGetter__("nothing") === undefined) + " on primitive: " + ((1).__lookupGetter__("x") === undefined) + " on null: " + kind(function () { Object.prototype.__lookupGetter__.call(null, "x"); }));
log.push("lookup key abrupt: " + kind(function () { o.__lookupGetter__({ toString: function () { throw new RangeError("no"); } }); }));
var names = ["__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__"].map(function (n) {
  var pd = Object.getOwnPropertyDescriptor(Object.prototype, n);
  return n + ":" + pd.value.name + "/" + pd.value.length + "/" + pd.enumerable + pd.writable + pd.configurable;
});
log.push("functions: " + names.join(" "));
console.log(log.join("\n"));
