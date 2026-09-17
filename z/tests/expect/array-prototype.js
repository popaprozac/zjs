// An array's [[Prototype]] can be changed like any object's: reads of
// named properties and of holes, inherited setters and read-only
// properties, null, cycles through arrays, objects, and functions,
// non-extensible arrays, enumeration, iteration, and an array serving as
// something else's prototype. A prototype reachable only through the
// array that inherits from it survives collection.
function churn() { var keep = []; for (var i = 0; i < 300; i++) { keep.push({ a: i, b: [i], c: "s" + i }); } return keep.length; }
function collect() { gc(); churn(); gc(); churn(); }
function show(label, f) { try { console.log(label, String(f())); } catch (e) { console.log(label, "throws", e && e.constructor ? e.constructor.name : e); } }
show("set and get:", function () { var a = [1, 2]; var p = { who: "p", get len2() { return this.length * 2; } }; Object.setPrototypeOf(a, p); return [Object.getPrototypeOf(a) === p, a.who, a.len2, a.length, Array.isArray(a), a instanceof Array, typeof a.push, p.isPrototypeOf(a), Array.prototype.isPrototypeOf(a)]; });
show("keep array methods by chaining:", function () { var a = [3, 1, 2]; var p = Object.create(Array.prototype); p.extra = function () { return this.length; }; Object.setPrototypeOf(a, p); a.push(9); return [a.extra(), a.sort().join(), a instanceof Array, a.map(function (x) { return x * 2; }).join()]; });
show("inherited setter, named key:", function () { var a = []; var p = { set v(x) { this._v = x; } }; Object.setPrototypeOf(a, p); a.v = 5; return [a._v, a.hasOwnProperty("v"), a.hasOwnProperty("_v")]; });
show("inherited readonly, named key:", function () { "use strict"; var a = []; var p = {}; Object.defineProperty(p, "ro", { value: 1, writable: false }); Object.setPrototypeOf(a, p); try { a.ro = 2; } catch (e) { return [e.constructor.name, a.ro, a.hasOwnProperty("ro")]; } return "no throw"; });
show("inherited index getter through a hole:", function () { var a = [1, , 3]; var p = Object.create(Array.prototype); Object.defineProperty(p, "1", { get: function () { return "from proto " + this.length; } }); Object.setPrototypeOf(a, p); return [a[1], 1 in a, a.hasOwnProperty(1), a.join("|")]; });
show("inherited index setter on an absent index:", function () { var a = []; var log = []; var p = Object.create(Array.prototype); Object.defineProperty(p, "0", { set: function (v) { log.push("set " + v); } }); Object.setPrototypeOf(a, p); a[0] = "x"; return [log.join(), a.length, a.hasOwnProperty(0)]; });
show("null prototype:", function () { var a = [1, 2, 3]; Object.setPrototypeOf(a, null); return [Object.getPrototypeOf(a), typeof a.push, a.length, a[1], Array.isArray(a), a instanceof Array, "length" in a, 1 in a, "push" in a, Array.prototype.join.call(a, "-")]; });
show("back from null:", function () { var a = [1]; Object.setPrototypeOf(a, null); Object.setPrototypeOf(a, Array.prototype); return [typeof a.push, a instanceof Array]; });
show("cycle direct:", function () { var a = [], b = []; Object.setPrototypeOf(a, b); return Object.setPrototypeOf(b, a); });
show("cycle through object and function:", function () { var a = []; var o = Object.create(a); function f() {} Object.setPrototypeOf(f, o); return Reflect.setPrototypeOf(a, f); });
show("self:", function () { var a = []; return Reflect.setPrototypeOf(a, a); });
show("non-extensible:", function () { var a = [1]; Object.preventExtensions(a); var r = [Reflect.setPrototypeOf(a, Array.prototype), Reflect.setPrototypeOf(a, {})]; try { Object.setPrototypeOf(a, {}); r.push("no throw"); } catch (e) { r.push(e.constructor.name); } r.push(Object.getPrototypeOf(a) === Array.prototype); return r; });
show("frozen and sealed:", function () { return [Reflect.setPrototypeOf(Object.freeze([1]), null), Reflect.setPrototypeOf(Object.seal([1]), {}), Reflect.setPrototypeOf(Object.freeze([1]), Array.prototype)]; });
show("array as prototype of object:", function () { var a = [10, 20]; a.named = "n"; var o = Object.create(a); return [o[0], o[1], o.length, o.named, typeof o.push, Array.isArray(o), o instanceof Array, 0 in o, o.hasOwnProperty(0)]; });
show("array as prototype of array:", function () { var base = ["b0", "b1", "b2"]; var a = ["a0"]; Object.setPrototypeOf(a, base); return [a[0], a[1], a[2], a.length, a.join(), typeof a.push]; });
show("array as prototype of function:", function () { function f() {} var a = [7]; a.tag = "t"; Object.setPrototypeOf(f, a); return [f[0], f.tag, f.length, typeof f.push, typeof f.call]; });
show("for-in and keys:", function () { var a = [1]; var p = { inherited: 1 }; Object.setPrototypeOf(a, p); var seen = []; for (var k in a) seen.push(k); return [seen.join(), Object.keys(a).join(), JSON.stringify(a), Object.getOwnPropertyNames(a).join()]; });
show("iteration and spread with custom proto:", function () { var a = [1, 2, 3]; var p = Object.create(Array.prototype); Object.setPrototypeOf(a, p); var r = [[...a].join(), Array.from(a).join()]; p[Symbol.iterator] = function* () { yield "custom"; }; r.push([...a].join()); var b = [1, 2]; Object.setPrototypeOf(b, null); try { [...b]; r.push("no throw"); } catch (e) { r.push(e.constructor.name); } return r; });
show("proto chain methods see the array:", function () { var a = [5, 6]; var p = Object.create(Array.prototype, { total: { get: function () { return this.reduce(function (s, x) { return s + x; }, 0); } } }); Object.setPrototypeOf(a, p); a.push(7); return [a.total, a.length]; });
show("__proto__-free checks:", function () { var a = []; var p = {}; Object.setPrototypeOf(a, p); return [Object.prototype.toString.call(a), a.constructor === Object, a.toString === Object.prototype.toString]; });
show("setPrototypeOf same value:", function () { var a = Object.preventExtensions([]); return [Reflect.setPrototypeOf(a, Array.prototype), Object.setPrototypeOf(a, Array.prototype) === a]; });
show("arguments and other exotics:", function () { var s = new String("ab"); Object.setPrototypeOf(s, { x: 1 }); var args = (function () { return arguments; })(1, 2); var p = { y: 2 }; Object.setPrototypeOf(args, p); return [s.x, s.length, s[0], typeof s.charAt, args.y, args.length, args[1]]; });

// --- collection ---
function inheriting() {
  var a = [1, 2, 3];
  Object.setPrototypeOf(a, Object.create(Array.prototype, {
    tag: { value: { reached: "only through the array" } },
    total: { get: function () { collect(); return this.reduce(function (s, x) { return s + x; }, 0); } },
    sink: { set: function (v) { collect(); this.got = v; } },
  }));
  return a;
}
show("a prototype held only by its array survives:", function () { var a = inheriting(); collect(); a.sink = { v: [1, 2] }; collect(); return [a.tag.reached, a.total, JSON.stringify(a.got), a.length, Object.getPrototypeOf(Object.getPrototypeOf(a)) === Array.prototype]; });
show("many arrays, each with its own prototype, under churn:", function () {
  var kept = [];
  for (var i = 0; i < 2000; i++) { var a = [i]; Object.setPrototypeOf(a, { n: i, list: [i, i + 1] }); if (i % 100 == 0) kept.push(a); churn(); }
  collect();
  return kept.map(function (a) { return a.n + ":" + a.list[1] + ":" + a[0]; }).join(" ");
});
show("a replaced prototype is let go, the new one kept:", function () { var a = []; Object.setPrototypeOf(a, { first: true }); Object.setPrototypeOf(a, { second: true }); collect(); Object.setPrototypeOf(a, Array.prototype); collect(); return [a.first, a.second, typeof a.push]; });
