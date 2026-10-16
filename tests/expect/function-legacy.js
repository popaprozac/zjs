// %Function.prototype% is callable, the restricted `caller` and
// `arguments` accessors, and NamedEvaluation through computed keys. Only
// outcomes are printed, never messages.
var log = [];
function kind(f) { try { f(); return "ok"; } catch (e) { return e.constructor.name; } }
var FP = Function.prototype;
log.push("callable: " + typeof FP + " " + (FP() === undefined) + " " + (FP.call(null, 1, 2) === undefined) + " " + JSON.stringify(FP.name) + " " + FP.length + " " + FP.hasOwnProperty("prototype") + " " + Object.prototype.toString.call(FP) + " " + (Object.getPrototypeOf(FP) === Object.prototype));
log.push("construct: " + kind(function () { new FP(); }));
log.push("still the prototype: " + (Object.getPrototypeOf(function () {}) === FP) + " " + ((function () {}) instanceof Function) + " " + (FP.constructor === Function));

var callerDesc = Object.getOwnPropertyDescriptor(FP, "caller");
var argumentsDesc = Object.getOwnPropertyDescriptor(FP, "arguments");
// The accessors' identity with %ThrowTypeError% and that function's own
// shape are specified but not what node does, so only the outcomes are here.
log.push("restricted accessors: " + (typeof callerDesc.get) + "/" + (typeof callerDesc.set) + " " + (typeof argumentsDesc.get) + "/" + (typeof argumentsDesc.set) + " enumerable " + callerDesc.enumerable + " configurable " + callerDesc.configurable + " " + kind(callerDesc.get) + " " + kind(argumentsDesc.set));
function strictFn() { "use strict"; }
log.push("strict function: get " + kind(function () { return strictFn.caller; }) + " " + kind(function () { return strictFn.arguments; }) + " set " + kind(function () { strictFn.caller = 1; }) + " " + kind(function () { strictFn.arguments = 1; }) + " own " + strictFn.hasOwnProperty("caller") + strictFn.hasOwnProperty("arguments"));
var arrow = function () { return () => 1; }();
class K { m() {} static s() {} }
function* gen() {}
var bound = strictFn.bind(null);
var shapes = [arrow, K, K.prototype.m, K.s, gen, bound, function () { "use strict"; }];
log.push("no own caller/arguments: " + shapes.map(function (f) { return f.hasOwnProperty("caller") || f.hasOwnProperty("arguments"); }).join(","));
log.push("class caller: " + kind(function () { return K.caller; }) + " method arguments: " + kind(function () { return K.prototype.m.arguments; }) + " bound: " + kind(function () { return bound.caller; }) + " generator: " + kind(function () { return gen.arguments; }));

function sloppy() {}
log.push("sloppy function: own " + sloppy.hasOwnProperty("caller") + sloppy.hasOwnProperty("arguments") + " reads " + (sloppy.caller === null) + " " + (sloppy.arguments === null) + " in " + ("caller" in sloppy) + " delete " + (delete sloppy.caller) + " set ignored " + kind(function () { "use strict"; sloppy.caller = 1; sloppy.arguments = 2; if (sloppy.caller !== null || sloppy.arguments !== null) throw new RangeError("kept"); }));
log.push("accessor on non-function: " + kind(function () { return callerDesc.get.call({}); }) + " " + kind(function () { callerDesc.set.call(1, 1); }));

var sym = Symbol("described");
var anon = Symbol();
var k = "computed";
var o = {
  [k]: function () {},
  [k + "Arrow"]: () => {},
  [k + "Class"]: class {},
  [k + "Method"]() {},
  [sym]: function () {},
  [anon]: function () {},
  [1 + 1]: function () {},
  [k + "Paren"]: (function () {}),
  [k + "Named"]: function keeps() {},
  get [k + "Get"]() { return 1; },
  set [k + "Set"](v) {}
};
function nameOf(v) { return JSON.stringify(v.name); }
log.push("computed names: " + [o.computed, o.computedArrow, o.computedClass, o.computedMethod, o[sym], o[anon], o[2], o.computedParen, o.computedNamed].map(nameOf).join(" "));
log.push("accessor names: " + JSON.stringify(Object.getOwnPropertyDescriptor(o, "computedGet").get.name) + " " + JSON.stringify(Object.getOwnPropertyDescriptor(o, "computedSet").set.name));
var nd = Object.getOwnPropertyDescriptor(o.computed, "name");
log.push("name attributes: writable " + nd.writable + " enumerable " + nd.enumerable + " configurable " + nd.configurable);
var calls = 0;
var keyObj = { toString: function () { calls++; return "once"; } };
var p = { [keyObj]: function () {} };
log.push("key converted once for naming: " + calls + " " + JSON.stringify(p.once.name));
console.log(log.join("\n"));
