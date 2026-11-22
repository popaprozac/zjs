// `this` as the left operand of `&&`, `||`, or `??` is read where it
// lives, and the operator's value takes a register of its own: the right
// operand's value never replaces `this` for what runs after, whatever the
// kind of function or initializer and wherever the expression stands.
var o = { k: 10, m() { return 3; } };
var log = [];
function show(name, ...values) { log.push(name + ": " + values.map(String).join(" ")); }
function both(value, self) { return [String(value), self === o ? "same" : "changed to " + String(self)].join(" / "); }

// The test of a conditional, the conditional an operand.
function f1(a) { return a + (this && this.k ? this.k : 0); }
function f2(a) { return (this && this.k ? this.k : 0) + a; }
function f3(a) { return a * (this && this.k ? this.k : 0); }
function f4(a) { return (() => a + (this && this.k ? this.k : 0))(); }
show("conditional operand", f1.call(o, 2), f2.call(o, 2), f3.call(o, 2), f4.call(o, 2));
show("conditional operand, falsy", f1.call({}, 2), f2.call({ k: 0 }, 2), f3.call({}, 2), f4.call({}, 2));

// Shapes beside it: `this` not read again, another left operand, a copy.
function v1(a) { return a + (this && this.k); }
function v2(a) { return a + (this ? 1 : 0); }
function v3(a) { return a + (this && 5); }
function v4(a) { return a + (this.k && this.k); }
function v5(a) { return a + (this || 0).k; }
function v6(a) { return a + (o && o.k ? o.k : 0); }
function v7(a) { var t = this; return a + (t && t.k ? t.k : 0); }
function v8(a) { return [a, this && this.k]; }
function v9(a) { return a + typeof (this && this.k); }
show("beside", v1.call(o, 2), v2.call(o, 2), v3.call(o, 2), v4.call(o, 2), v5.call(o, 2), v6.call(o, 2), v7.call(o, 2), v8.call(o, 2), v9.call(o, 2));

// `this` after each operator, the right operand evaluated and not.
function andThen() { var x = this && 1; return both(x, this); }
function orThen() { var x = this || 1; return both(x === this, this); }
function nullishThen() { var x = this ?? 1; return both(x === this, this); }
function strictAnd() { "use strict"; var x = this && 1; return [x, this].join(); }
function strictOr() { "use strict"; var x = this || 7; return [x, this].join(); }
function strictNullish() { "use strict"; var x = this ?? 7; return [x, this].join(); }
show("after", andThen.call(o), orThen.call(o), nullishThen.call(o));
show("after, strict and", strictAnd.call(5), strictAnd.call(0), strictAnd.call(""));
show("after, strict or", strictOr.call(5), strictOr.call(0), strictOr.call(""), strictOr.call(null));
show("after, strict nullish", strictNullish.call(5), strictNullish.call(0), strictNullish.call(null), strictNullish.call(undefined));

// Chains, and the operator inside other expressions.
function chain() { return [this && this.k && this.m(), this || this.k || 0, this ?? this.k, (this && this.k) || this, !(this && this.k), this.k].join(); }
function nested() { return [(this && this) === this, (this || 1) && (this && this.k), `${this && this.k}${this.k}`, [this && 1, this.k] + "", { a: this && 2, b: this.k }.b].join(); }
function argument() { return both(String(this && 1, this), this) + " " + [this && 1, this].indexOf(this) + " " + Math.max(this && 4, this.k); }
function assigned() { var x; x = this && 1; var y = (x = this || 2) && this.k; return both([x === this, y], this); }
show("chains", chain.call(o), nested.call(o), argument.call(o), assigned.call(o));

// As a test.
function inIf() { if (this && this.k) return this.k; return "none"; }
function inElse() { if (!(this && this.k)) return "none"; else return this.k; }
function inReturn() { return this && this.k ? this.k : 0; }
function inWhile() { var n = 0; while (this && this.k && n < 30) n += this.k; return n; }
function inFor() { var n = 0; for (var i = 0; this && i < 3; i++) n += this.k; return n; }
function inDo() { var n = 0; do { n += this.k; } while (this && this.k && n < 30); return n; }
function inSwitch() { switch (this && this.k) { case 10: return this.k; default: return "no " + typeof this; } }
show("tests", inIf.call(o), inElse.call(o), inReturn.call(o), inWhile.call(o), inFor.call(o), inDo.call(o), inSwitch.call(o));
show("tests, falsy", inIf.call({}), inElse.call({}), inReturn.call({}), inWhile.call({}), inSwitch.call({}));

// In a parameter's default and a pattern's.
function inDefault(a = this && 4, b = this.k) { return both([a, b], this); }
function inPattern() { var { p = this && 3, q = this.k } = {}; var [r = this || 0] = []; return both([p, q, r === this], this); }
show("defaults", inDefault.call(o), inPattern.call(o));

// Each kind of function.
var arrowOwner = { k: 1, run() { var f = () => { var x = this && 2; return [x, this === arrowOwner].join(); }; return f(); } };
var accessors = { k: 1, get g() { var x = this && 2; return this === accessors; }, set s(v) { var x = this || v; this.seen = this === accessors; } };
accessors.s = 1;
show("arrow, accessors", arrowOwner.run(), accessors.g, accessors.seen);
function Plain() { this.a = this && 1; this.b = 2; }
var plain = new Plain();
show("constructor", plain.a, plain.b);
class Base {
  constructor() { this.first = this && 1; this.second = this instanceof Base; }
  m() { var x = this && this.first; return this instanceof Base; }
  five() { return 5; }
  static s() { var x = this || 0; return this === Base; }
}
class Derived extends Base {
  field = this && 6;
  self = this;
  constructor() { super(); var x = this && 1; this.ok = this instanceof Derived; }
  viaSuper() { var x = this && super.five(); var y = super.five() && this; return [x, y === this, this instanceof Derived].join(); }
}
var derived = new Derived();
show("classes", derived.first, derived.second, derived.m(), Base.s(), derived.ok, derived.field, derived.self === derived, derived.viaSuper());

// A static initializer's `this` is the class.
class Statics { static a = this && 1; static b = this === Statics; static c = this || 2; static { var x = this ?? 3; Statics.d = this === Statics; } }
var Expression = [class { static a = this && 7; static b = this; static n = (this || 0).name.length; }][0];
show("statics", Statics.a, Statics.b, Statics.c === Statics, Statics.d, typeof Expression, Expression.a, Expression.b === Expression, Expression.n);

// Across a suspension, and through eval.
function* gen() { var x = this && (yield 1); return both(x, this); }
var it = gen.call(o);
it.next();
show("generator", it.next(6).value);
function viaEval() { var x = eval("this && 2"); var y = eval("var z = this && 3; this === o"); return both([x, y], this); }
show("eval", viaEval.call(o));
show("top level", (this && 1, typeof this), (this || 1, typeof this));
async function later() { var x = this && (await 8); return both(x, this); }
later.call(o).then(function (value) {
  show("async", value);
  console.log(log.join("\n"));
});
