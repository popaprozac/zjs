var log = [];
var o = {};
Object.defineProperty(o, "fixed", { value: 1 });
Object.defineProperty(o, "open", { value: 2, writable: true, enumerable: true, configurable: true });
o.fixed = 9;
o.open = 3;
var d = Object.getOwnPropertyDescriptor(o, "fixed");
log.push(o.fixed, o.open, d.value, d.writable, d.enumerable, d.configurable, Object.keys(o).join(), Object.getOwnPropertyNames(o).join());
var count = 0;
var acc = { get x() { return count * 10; }, set x(v) { count = v; } };
acc.x = 4;
var ad = Object.getOwnPropertyDescriptor(acc, "x");
log.push(acc.x, count, typeof ad.get, typeof ad.set, ad.enumerable, ad.configurable, "value" in ad);
Object.defineProperty(o, "computed", { get: function () { return this.open + 100; }, configurable: true });
log.push(o.computed, Object.keys(o).length);
var frozen = Object.freeze({ a: 1, nested: { b: 2 } });
frozen.a = 2; frozen.c = 3; delete frozen.a; frozen.nested.b = 5;
log.push(frozen.a, frozen.c, frozen.nested.b, Object.isFrozen(frozen), Object.isFrozen(frozen.nested), Object.isSealed(frozen), Object.isExtensible(frozen));
var sealed = Object.seal({ s: 1 });
sealed.s = 2; sealed.t = 3; delete sealed.s;
log.push(sealed.s, sealed.t, Object.isSealed(sealed), Object.isFrozen(sealed));
var strictResult = "";
(function () { "use strict"; try { frozen.a = 5; } catch (e) { strictResult = e.name; } })();
log.push(strictResult);
var arr = [1, 2, 3];
arr[5] = 1;
Object.defineProperty(arr, "length", { writable: false });
arr[1] = 20;
log.push(arr.length, Object.getOwnPropertyDescriptor(arr, "length").writable, Object.getOwnPropertyDescriptor(arr, "0").enumerable, Object.keys(arr).join(), Object.getOwnPropertyNames(arr).join(), arr[1]);
log.push(Object.getOwnPropertyDescriptor(Math, "abs").enumerable, Object.keys(Math).length, Object.getOwnPropertyDescriptor(function f(a, b) {}, "length").value, Object.getOwnPropertyDescriptor(Math.abs, "name").value, Object.getOwnPropertyDescriptor(Math.abs, "length").configurable, "prototype" in Math.abs, Object.getOwnPropertyDescriptor(Object, "prototype").writable);
var proto = { inherited: 1 };
var child = Object.create(proto, { own: { value: 2, enumerable: true } });
log.push(child.inherited, child.own, Object.getPrototypeOf(child) === proto, Object.getPrototypeOf(Object.create(null)), Object.keys(child).join(), "inherited" in child);
Object.setPrototypeOf(child, null);
log.push(child.inherited, Object.getPrototypeOf(child));
var target = Object.assign({ a: 1 }, { b: 2 }, null, { a: 3 });
log.push(Object.keys(target).join(), target.a, Object.entries({ x: 1, y: 2 }).join(";"), Object.values({ x: 1, y: 2 }).join(), Object.is(NaN, NaN), Object.is(0, -0), Object.hasOwn(target, "b"), Object.fromEntries([["k", "v"]]).k, target.propertyIsEnumerable("a"), Object.keys({ 2: 1, b: 1, 1: 1, a: 1 }).join());
var caught = [];
try { Object.defineProperty(o, "fixed", { value: 2 }); } catch (e) { caught.push(e.name); }
try { Object.defineProperty(o, "fixed", { value: 1 }); caught.push("same-ok"); } catch (e) { caught.push(e.name); }
try { Object.defineProperty(1, "x", {}); } catch (e) { caught.push(e.name); }
try { Object.defineProperty(o, "bad", { get: 1 }); } catch (e) { caught.push(e.name); }
try { Object.defineProperty(o, "mixed", { get: function () {}, value: 1 }); } catch (e) { caught.push(e.name); }
log.push(caught.join());
log.join("|");
