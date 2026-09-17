// A function written as an object literal's method, getter, or setter
// has no [[Construct]] and no `prototype`; a function-valued property
// (`{ f: function () {} }`, a class, a named function expression) is an
// ordinary function and keeps both. Class members are as they were.
function show(label, f) { try { console.log(label, String(f())); } catch (e) { console.log(label, "throws", e && e.constructor ? e.constructor.name : e); } }
function ctor(f) { try { new f(); return "constructs"; } catch (e) { return e.constructor.name; } }
var key = "computed", sym = Symbol("s");
var o = {
  method() { return 1; },
  [key]() { return 2; },
  [sym]() { return 3; },
  "quoted"() {}, 42() {},
  get getter() { return 4; }, set setter(v) {}, get [key + "G"]() { return 5; }, set [key + "S"](v) {},
  async am() {}, *gm() {}, async *agm() {},
  plain: function () { this.made = true; },
  named: function named() {},
  arrow: () => 1,
  klass: class {},
  nested: { inner() {}, prop: function () {} },
};
var d = function (k) { return Object.getOwnPropertyDescriptor(o, k); };
show("methods:", function () { return [ctor(o.method), ctor(o[key]), ctor(o[sym]), ctor(o.quoted), ctor(o[42])]; });
show("accessors:", function () { return [ctor(d("getter").get), ctor(d("setter").set), ctor(d("computedG").get), ctor(d("computedS").set)]; });
show("async and generator methods:", function () { return [ctor(o.am), ctor(o.gm), ctor(o.agm)]; });
show("function-valued properties stay constructable:", function () { return [ctor(o.plain), ctor(o.named), ctor(o.klass), new o.plain().made, ctor(o.nested.prop)]; });
show("others:", function () { return [ctor(o.arrow), ctor(o.nested.inner)]; });
show("no prototype property on methods and accessors:", function () { return [o.method.hasOwnProperty("prototype"), "prototype" in o.method, typeof o.method.prototype, d("getter").get.hasOwnProperty("prototype"), d("setter").set.hasOwnProperty("prototype"), Object.getOwnPropertyNames(o.method).sort().join()]; });
show("prototype where there should be one:", function () { return [o.plain.hasOwnProperty("prototype"), o.named.hasOwnProperty("prototype"), o.gm.hasOwnProperty("prototype"), o.agm.hasOwnProperty("prototype"), o.am.hasOwnProperty("prototype"), o.arrow.hasOwnProperty("prototype")]; });
show("still callable, with this and super:", function () { var base = { hi() { return "base hi"; } }; var derived = { __proto__: null, hi() { return "derived"; } }; var obj = { hi() { return super.hi() + " via " + typeof this; } }; Object.setPrototypeOf(obj, base); return [o.method(), o[key](), o[sym](), o.getter, obj.hi()]; });
show("a method given a prototype is still not a constructor:", function () { var m = ({ m() {} }).m; m.prototype = { given: true }; return [ctor(m), m.prototype.given, Object.getOwnPropertyDescriptor(m, "prototype").enumerable]; });
show("bound methods and accessors:", function () { return [ctor(o.method.bind(null)), ctor(d("getter").get.bind(null)), ctor(o.plain.bind(null)), "prototype" in o.method.bind(null)]; });
show("Reflect.construct and instanceof:", function () { var r = []; try { Reflect.construct(o.method, []); r.push("constructs"); } catch (e) { r.push(e.constructor.name); } try { Reflect.construct(Object, [], o.method); r.push("new target ok"); } catch (e) { r.push(e.constructor.name); } try { r.push({} instanceof o.method); } catch (e) { r.push(e.constructor.name); } r.push({} instanceof o.plain); return r; });
show("class extends a method:", function () { class D extends o.method {} return new D(); });
show("class members are as before:", function () { class K { m() {} static s() {} get g() { return 1; } static f = function () {}; } var pd = Object.getOwnPropertyDescriptor(K.prototype, "g"); return [ctor(K.prototype.m), ctor(K.s), ctor(pd.get), ctor(K.f), ctor(K)]; });
show("names and lengths unchanged:", function () { return [o.method.name, d("getter").get.name, d("setter").set.name, o.plain.name, o.named.name, o.method.length, d("setter").set.length]; });
