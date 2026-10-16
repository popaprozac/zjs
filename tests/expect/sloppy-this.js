// A sloppy function that reads `this` sees a primitive receiver wrapped
// in an object and no receiver as the global object; strict code sees
// the receiver as it is.
Boolean.prototype.f = function () { return typeof this; };
Boolean.prototype.g = function () { "use strict"; return typeof this; };
console.log(true.f(), true.g(), [true].map(function () { return typeof this; }, true)[0]);
Boolean.prototype.toLocaleString = function () { return typeof this; };
console.log([true].toLocaleString());

String.prototype.me = function () { return this instanceof String ? "wrapped:" + this.length : "raw"; };
Number.prototype.me = function () { return typeof this + ":" + (this + 1); };
console.log("abc".me(), (5).me(), (2.5).me());
function sloppy() { return this; }
function strict() { "use strict"; return this; }
console.log(typeof sloppy.call(1), typeof strict.call(1), sloppy.call(undefined) === globalThis, strict.call(null));
console.log(typeof sloppy.apply("s"), typeof sloppy.bind(true)(), typeof Reflect.apply(sloppy, 7, []));
var sym = Symbol("s");
console.log(typeof sloppy.call(sym), sloppy.call(sym).valueOf() === sym);

// Each call wraps anew; the value inside is the primitive.
var w1 = sloppy.call(3), w2 = sloppy.call(3);
console.log(w1 === w2, w1 == 3, w1.valueOf() + w2.valueOf());

// Arrows and generators see the same wrapped `this`.
function outer() { return (() => typeof this)(); }
console.log(outer.call("x"), outer.call(undefined));
function* gen() { yield typeof this; yield (() => typeof this)(); yield this === globalThis; }
var it = gen.call(5);
console.log(it.next().value, it.next().value, it.next().value);
var it2 = gen();
console.log(it2.next().value, it2.next().value, it2.next().value);
