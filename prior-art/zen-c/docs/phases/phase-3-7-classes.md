# zjs Phase 3.7 — Class syntax

> Sugar on top of Phase 3.6's prototype-chain + `new` + `this`. A class
> declaration desugars at compile time to a function plus
> `Class.prototype.method = ...` assignments. The runtime sees nothing
> new — only the parser/compiler grow.

## Scope

### Syntax supported

```js
class Counter {
  constructor() { this.n = 0; }
  inc() { this.n = this.n + 1; return this.n; }
  reset() { this.n = 0; }
}

let c = new Counter();
c.inc(); c.inc();
c instanceof Counter   // true
```

Both forms:
- **`class Name { ... }`** — class declaration, binds `Name` like a
  function declaration.
- **`let X = class { ... }`** — class expression. Optional name after
  the `class` keyword (currently doesn't bind inside the body — minor
  deviation from spec).

### Members (MVP)

- One **constructor** (optional; default is empty).
- Any number of **instance methods**.

Each member is parsed as a `MethodDef` AST node that shares the
`FunctionExpr` shape (`children = params`, `left = body`, `name_*`).
The compiler distinguishes the constructor by its name being literally
`"constructor"`.

## Desugaring

`class Foo { constructor(args) { body } m1() { b1 } m2() { b2 } }`
compiles to the same bytecode you'd get for:

```js
function Foo(args) { body }
Foo.prototype.m1 = function () { b1 };
Foo.prototype.m2 = function () { b2 };
```

Concretely, `compile_class_value` does:
1. Find the constructor `MethodDef` (or synthesize an empty `FunctionExpr`-shaped
   stack node if missing).
2. `compile_function(...)` it → `Function*` → register in constants →
   `LoadConst ctor_reg`. Closure-wrap if any captures span out.
3. `LoadProp proto_reg, ctor_reg, ic("prototype")` — relies on
   `property_get`'s lazy auto-create of `Function.prototype` from 3.6.
4. For each non-constructor method: compile to a `Function*`, load
   it, closure-wrap if needed, then `StoreProp proto_reg,
   ic(method_name), method_reg`.
5. Return `ctor_reg`. `ClassDecl` binds it; `ClassExpr` returns it as
   the expression value.

`collect_locals` adds the class name as a function-scoped local (same
as `FunctionDecl`). `analyze_captures` walks each `MethodDef`'s body
to find outer-name captures, treating methods as nested functions —
so a method that references an outer `let` triggers the env-object
machinery on the enclosing scope, just like a nested function does.

## Out of scope (deferred)

- **`extends`** — needs an explicit proto link between
  `Sub.prototype` and `Super.prototype`, plus `super(args)` and
  `super.method()`. Tracked as a follow-up.
- **Static members** (`static methodName()`). Easy follow-up: attach
  to the constructor function itself instead of its prototype.
- **Getters / setters** (`get x() {...}`). Would need an
  accessor-descriptor model on objects — bigger change.
- **Private fields** (`#foo`). Spec is fresh; can wait.
- **Class fields** (`class X { count = 0 }`). Sugar for initialization
  inside the constructor; easy follow-up.
- **Class expression's name binding inside its own body** — the name
  is parsed and stored but not bound; minor spec deviation.
- **`new.target`** — not implemented.
- **Auto-bound `this` in arrow methods inside classes** — works
  through normal closure capture if you write
  `let self = this; let fn = () => self.foo`. Real lexical-this for
  arrows is a future item.

## Verification

```bash
zjs eval "class C { constructor() { this.n = 0 } inc() { this.n = this.n + 1; return this.n } } let c = new C(); c.inc(); c.inc(); c.inc()"
# => 3

zjs eval "class B { constructor(v) { this.value = v } get() { return this.value } } new B(42).get()"
# => 42

zjs eval "class A { constructor(b) { this.base = b } add(x) { return this.base + x } } let a = new A(10); a.add(5) + a.add(20)"
# => 45

zjs eval "class P {} (new P()) instanceof P"   # true
zjs eval "let C = class { foo() { return 7 } }; new C().foo()"   # 7
```

9 new tests cover constructor+method, ctor args, instanceof, plain
class expression (anonymous and named), shared-prototype behavior,
and distinct `this` across instances.

## What's next

- **`extends` + `super`** — the natural next class feature.
- **Static methods + class fields** — small, mechanical.
- **Error.prototype wiring** so `e instanceof Error` works.
- **break/continue** — long-deferred loop concern, unrelated to
  classes but it's the next time we touch loops.
- **AOT bytecode (zjsc)** — pre-compile + cache; major for cold-start
  perf on iOS.
- **Bare `libjs` adapter** — the load-bearing integration test with
  zapp; lets the engine plug into the bare-js runtime alongside
  libhermes / libjsc / libqjs.
