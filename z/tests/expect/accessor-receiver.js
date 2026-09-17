// An accessor inherited along a chain of constructors runs against the
// constructor the read began on, not the one that holds the accessor.
class Base {
  static get self() { return this; }
  static get label() { return "label of " + this.name; }
}
class Middle extends Base {}
class Leaf extends Middle {}
console.log(Base.self === Base, Middle.self === Middle, Leaf.self === Leaf);
console.log(Base.label, "|", Middle.label, "|", Leaf.label);
class Overriding extends Base { static get self() { return "own"; } }
console.log(Overriding.self, Overriding.label);

// Symbol.species on the builtins is such an accessor.
class M extends Map {}
class S extends Set {}
class A extends Array {}
class P extends Promise {}
class R extends RegExp {}
console.log(M[Symbol.species] === M, S[Symbol.species] === S, A[Symbol.species] === A, P[Symbol.species] === P, R[Symbol.species] === R);
console.log(Map[Symbol.species] === Map, Promise[Symbol.species] === Promise);
class PP extends P {}
console.log(PP[Symbol.species] === PP);
var getter = Object.getOwnPropertyDescriptor(Promise, Symbol.species).get;
console.log(getter.call(7), getter.call(P) === P);

// Data properties and the virtual ones are unaffected.
class WithData { static value = 1; }
class InheritsData extends WithData {}
console.log(InheritsData.value, InheritsData.name, InheritsData.length, Object.getPrototypeOf(InheritsData) === WithData);
