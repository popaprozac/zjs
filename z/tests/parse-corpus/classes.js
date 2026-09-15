class Empty {}
class Point { constructor(x, y) { this.x = x; this.y = y; } }
class Fields { a = 1; b; static c = 3; static d; 'quoted' = 4; [computed] = 5; static [k] = 6; #priv = 7; static #sp; }
class Methods {
  method() {} static sm() {} async am() {} *gm() {} async *agm() {} static async sam() {} static *sgm() {}
  get g() { return 1; } set g(v) {} static get sg() {} static set sg(v) {}
  [computed]() {} static [computed2]() {} get [ck]() {} 'string name'() {} 42() {} if() {} static() {} get() {} set() {} async() {}
  #pm() { return this.#priv; } static #spm() {} get #pg() {} has(o) { return #pm in o; }
}
class Derived extends Base { constructor(...args) { super(...args); super.method(); } method() { return super.method(); } }
class DerivedFields extends Base { x = 1; }
class WithStatic { static { init(); let a = 1; } static count = 0; static { WithStatic.count++; } }
class Extends2 extends (mixin(A, B)) {}
class Extends3 extends foo.bar.Baz {}
var E = class {};
var N = class Named extends Base { m() {} };
f(class { x = 1; });
class Semis { ; a = 1; ; method() {} ; }
class ASI { a = 1
  b = 2
  method() {} }
