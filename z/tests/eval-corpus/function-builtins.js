var log = [];
function add(a, b, c) { return this.base + a + b + c; }
var bound = add.bind({ base: 100 }, 1);
log.push(bound(2, 3), typeof bound, bound.call({ base: 0 }, 5, 6));
function Point(x, y) { this.x = x; this.y = y; }
var BoundPoint = Point.bind(null, 7);
var p = new BoundPoint(8);
log.push(p.x, p.y, p instanceof Point, p instanceof BoundPoint);
var made = new Function("a", "b", "return a * b");
var noArgs = Function("return 42");
log.push(made(6, 7), noArgs(), typeof made, made.length, Function.prototype === Object.getPrototypeOf(made), Object.getPrototypeOf(Math.abs) === Function.prototype, Function.prototype.constructor === Function);
var caught = [];
try { new Math.abs(); } catch (e) { caught.push(e.name); }
try { new (function () {}).bind()(); caught.push("bound-ok"); } catch (e) { caught.push(e.name); }
try { Reflect.construct(function () {}, [], Math.abs); } catch (e) { caught.push(e.name); }
try { Function.prototype.bind.call(1); } catch (e) { caught.push(e.name); }
log.push(caught.join());
log.push(Reflect.apply(Math.max, null, [1, 9, 3]), Reflect.has({ a: 1 }, "a"), Reflect.get({ a: 1 }, "a"), Reflect.set({}, "k", 1), Reflect.ownKeys({ b: 1, a: 2, 1: 3 }).join(), Reflect.getPrototypeOf([]) === Array.prototype, Reflect.deleteProperty({ x: 1 }, "x"), Reflect.isExtensible(Object.freeze({})), Reflect.construct(Point, [1, 2]).y);
function Base() { this.made = true; }
var viaReflect = Reflect.construct(Base, [], Point);
log.push(viaReflect.made, viaReflect instanceof Point, viaReflect instanceof Base);
log.join("|");
