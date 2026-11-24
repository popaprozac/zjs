// A module's own code is in no function, but a field's initializer and
// a function's or a method's parameters are: `new.target` there is
// undefined, or the function when it is called with `new`.
class C {
  x = new.target;
  y = () => new.target;
  static s = new.target;
  m(a = new.target) { return a; }
}
function f(a = new.target) { return a; }
const made = new C();
console.log(made.x, made.y(), C.s, made.m(), f(), new f() === f);
// Indirect eval code is a script's: an arrow there is in no function.
let out;
try { (0, eval)("() => new.target"); out = "ok"; } catch (e) { out = e.constructor.name; }
console.log(out);
