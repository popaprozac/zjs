# zjs Phase 3.3 — Closures (Environment-Object Model)

> Real JavaScript needs closures everywhere — callbacks, factories,
> module patterns, iterator helpers. This phase adds them with the
> simplest model that's correct under JS reference semantics:
> captured locals live in a heap-allocated environment **object**
> shared by reference between the outer scope and any inner functions.

## Scope

In scope:
- New cell type `ZjsClosure { function, env }` (`TAG_CLOSURE = 7`)
- Function struct gains:
  - `needs_env: bool` — set by the compiler when this function contains nested functions that capture its locals
  - `captures: ZjsString**` — list of names this function references from its enclosing scope (atoms)
  - `capture_count: u32`
- Pre-pass capture analysis:
  - For each `FunctionDecl` / `FunctionExpr` / `ArrowFunc` in the current function's body, recursively collect identifiers it references that are local in the *current* scope but not in the inner scope
  - Mark those outer locals as **captured** — they get stored in the outer's env object
- Outer function code generation:
  - If `needs_env`, allocate an env object at function entry
  - Captured locals: every read/write goes through the env (via the existing object-property machinery — atom-interned name, IC-cacheable)
  - Non-captured locals stay in regs (fast path unchanged)
- Inner function (closure) code:
  - References to outer-scope names emit:
    - `LoadEnv tmp` — load `current_closure.env` into a register
    - then `LoadProp dst, tmp, ic_slot` (with the captured name as IC name) — IC-cacheable!
  - Same for writes (`StoreProp`)
- New opcodes:
  - `MakeClosure dst, fn_reg, env_reg` — pack `{ fn, env }` into a Closure cell
  - `LoadEnv dst` — `regs[dst] = current_closure.env` (or `undefined` if no closure)
- Calling convention extension:
  - `Op::Invoke` dispatches on tag: user `Function` (no env) or `Closure` (set current_closure for the duration of the call)
  - Context tracks `current_closure` across nested calls (push/pop)

What this gives us:
- The classic counter pattern works:
  ```js
  function makeCounter() {
      let count = 0;
      return function() { count = count + 1; return count; };
  }
  let c = makeCounter();
  c(); c(); c();   // 3
  ```
- Captured locals follow JS reference semantics — multiple closures over the same outer call share their env
- Arbitrary nesting works if we walk the env chain (deferred for MVP — only one level for now)

Out of scope:
- **Multi-level capture** — inner closures only see their immediate parent's env. Deep nests like `function a() { let x; function b() { function c() { x; } } }` won't work until we add env chaining.
- **`let` block scoping inside closures** — captured locals are function-scoped (which is the JS `var` semantic anyway for the captured ones)
- **Optimized "non-captured locals stay in regs even when needs_env"** — for MVP, if a function has any nested function, ALL its locals go in the env. Slower but correctly captures every reference.
- **Tail-call optimization through closures**
- **`this` binding** — arrow functions capture lexical `this`; we don't have `this` machinery yet anyway
- **Closure compaction / shape-based optimization** for shared closures

## Architecture

```
                                ┌──────────────┐
                                │  Function    │  (the immutable template
                                │  (template)  │   stored in constants)
                                └──────┬───────┘
                                       │
                                       ▼
                                ┌──────────────┐       ┌──────────────┐
                                │  Closure     │──env──│  Object      │  (the runtime env;
                                │ {fn, env}    │       │              │   shared by all
                                └──────┬───────┘       │ captured     │   closures from
                                       │               │ locals as    │   the same outer
                                       ▼               │ properties   │   call)
                                  call site            └──────────────┘
                              (interpret reads        properties access
                               ctx.current_closure)    is IC-cached
```

## Compile-time capture analysis

For each function body being compiled, we run a pre-pass that visits the AST:

1. Track the function's own locals (params + var/let/const decls).
2. For each nested function in the body, recursively collect its **free references** (identifiers that aren't its own locals).
3. Any free reference whose name matches a local in *this* function → that local is captured.

The captured set drives two things:
- This function gets `needs_env = true` (env object will be allocated at entry).
- The inner function's `captures` list records which outer names it depends on.

## Verification

Programs that should now work:

```bash
zjs eval "function makeCounter() { let count = 0; return function() { count = count + 1; return count } } let c = makeCounter(); c(); c(); c()"
# => 3

zjs eval "function adder(a) { return function(b) { return a + b } } adder(10)(5)"
# => 15

zjs eval "function once(fn) { let called = false; return function() { if (!called) { called = true; return fn() } return undefined } } let f = once(function() { return 42 }); f(); f()"
# => undefined (second call falls through; once-only behavior)
```

Plus the full existing test suite stays green.

## Optimization path

The env-object model is a **stepping stone**, not the destination.
Captured-local access goes through the property-access machinery
(LoadProp / StoreProp), which means:

- Every captured-local read is one IC lookup (cached → 1 pointer compare + 1 indexed load — basically as fast as a direct slot read)
- Every captured-local write is the same
- Cold-cache cost is one full hidden-class walk (very small in practice — depth ≈ number of captured names)

Because our IC infrastructure (Phase 3.2b) makes property access cheap
when the shape is stable, this approach is **acceptable for a v1**.
The shape of an env object never changes after a function entry, so
the ICs warm up immediately and never thrash. The overhead vs. direct
register access is essentially one indirection per access.

The future optimized path:
- **Upvalue boxes** (Lua-style): each captured local is a heap-allocated 1-slot box. Outer + inner share the box directly. One indirection per access, no hidden-class lookup at all. Slightly faster than env-object.
- **Escape analysis**: at compile time, prove whether a captured local *needs* heap allocation (does any closure escape the outer call?). If not, the local can stay in a register and the closure binds directly to that register slot until the outer returns. Hermes does a version of this.
- **Specialized opcodes** (`LoadUpvalue` / `StoreUpvalue` directly indexed): bypasses the property-access path entirely. Indexed load into closure.upvalues array.

We'll measure the env-object approach against real workloads (test262
+ representative programs) and migrate when profiling shows the
overhead is meaningful. The Phase 3.2b ICs do most of the heavy
lifting here — without them, this approach would be much worse.

## What's next

- **3.4 — for-in / for-of execution.** Parser already handles them; bytecode lowering pending.
- **3.5 — more built-ins** (Object.keys, Array.prototype.{push, pop, indexOf, map, forEach}, String.prototype.{indexOf, slice, split}, JSON.{stringify, parse}).
- **3.6 — prototype chain + instanceof.** Unlocks classes (3.7) and Error-instance checks in test262.
- **Multi-level closure capture** when we need it.
- **Upvalue-box closure rewrite** when the env-object overhead becomes measurable.
