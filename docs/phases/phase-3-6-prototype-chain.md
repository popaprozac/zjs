# zjs Phase 3.6 — Prototype chain + instanceof + this + new

> Adds the foundation that makes constructor-style JS work. After this
> phase, classes (3.7) are mostly a syntax-sugar layer on top.

## Scope

- **`ZjsObject.proto: ZjsObject*`** — the [[Prototype]] slot. NULL = top
  of chain. Walked by `property_get` after the own-property lookup misses.
- **Function/HostFunction `.prototype`** — lazy `ZjsObject*` field on
  both. First access (read OR `new`) creates an empty object; later
  reads return the same one. Settable via `Fn.prototype = {...}`.
- **Op::In** — `key in obj`: own property, proto-chain, or built-in
  intercept (`length` on arrays + the array/string proto methods).
- **Op::Instanceof** — `val instanceof Ctor`: walks `val.__proto__`
  chain looking for `Ctor.prototype`.
- **Op::LoadThis** — reads `ctx.host_this`, which is now set by all
  call paths:
  - `Invoke` (plain call): `this = undefined`
  - `MethodInvoke` (`obj.method()`): `this = obj`
  - `NewInvoke` (`new Foo()`): `this = new object`
- **Op::NewInvoke** — allocates a fresh object whose proto is
  `Ctor.prototype`, binds it as `this`, calls Ctor. If Ctor explicitly
  returns an object/array, that value is the result; otherwise the new
  object is.
- **`Object.create(proto)`** — host function that allocates `{}` with
  the given proto.
- **`Object.getPrototypeOf(obj)`** — host function that returns
  `obj.proto` or null.

## Compile-time changes

- `Binary` with `op == KwIn` or `op == KwInstanceof` no longer routes
  through `binary_op` (which only knows arithmetic) — `compile_expr`
  intercepts and emits `Op::In` / `Op::Instanceof` directly.
- `ThisExpr` compiles to `LoadThis`.
- `NodeKind::New` previously fell through to `compile_call` (so `new
  Foo()` was just a regular call). It now emits `Op::NewInvoke` with
  the same `{callee, ...args}` slot layout as `Invoke`.

## What this enables

```js
// Constructor pattern works end-to-end
function Counter() { this.n = 0; }
Counter.prototype.inc = function () {
  this.n = this.n + 1;
  return this.n;
};
let c = new Counter();
c.inc(); c.inc(); c.inc();   // 3
c instanceof Counter;        // true

// Prototype inheritance via Object.create
const animal = { speak() { return this.name + ' speaks'; } };
const dog = Object.create(animal);
dog.name = 'Rex';
dog.speak();                 // "Rex speaks"
```

## Out of scope

- **`__proto__` accessor** (gettable/settable on objects). Use
  `Object.{create, getPrototypeOf}` instead.
- **`Object.setPrototypeOf`** — easy follow-up; not needed for
  classes.
- **`Object` as a constructor** (`new Object()`). `Object` is the
  static-namespace object here, not a function. `obj instanceof
  Object` returns false. Class syntax (3.7) handles its own ctor
  setup, so this gap doesn't block classes.
- **Inheritance via `class X extends Y`** — comes with the class
  desugaring in 3.7.
- **`Error.prototype` setup** — `e instanceof Error` won't work until
  we wire host_error to set its result's proto. Tracked separately;
  not strictly part of the prototype-chain mechanism itself.
- **`this` in non-method, non-new calls** — bound to `undefined`,
  matching strict-mode JS. (Sloppy-mode `this`-coerces-to-global is
  deliberately not implemented.)

## Verification

```bash
zjs eval "let p={greet:'hi'}; let o=Object.create(p); o.greet"           # "hi"
zjs eval "function P(x){this.x=x} (new P(7)).x"                          # 7
zjs eval "function C(){this.n=0} C.prototype.inc=function(){this.n=this.n+1;return this.n}; let c=new C(); c.inc();c.inc();c.inc()"  # 3
zjs eval "function F(){} if ((new F()) instanceof F) 1; else 0"          # 1
zjs eval "let o={n:5, g:function(){return this.n}}; o.g()"               # 5
zjs eval "if ('length' in [1,2,3]) 1; else 0"                            # 1
```

17 new tests cover Object.create + chain lookup, in (own / proto /
array index / "length"), constructor pattern, instanceof,
this-in-methods, this-in-shared-proto-methods, function.prototype
identity.

## What's next

- **3.7 — class syntax.** Desugar `class X { constructor() {} method() {} }`
  to a function with .prototype populated. `extends` adds an explicit
  proto link between class.prototype objects.
- **Error.prototype wiring** + `e instanceof Error`.
- **`Object.setPrototypeOf`** when needed.
