# Future work — items we've deferred deliberately

A running list of architectural items that are spec'd and ready but
deferred. Each entry includes the trigger that should pull it forward
and the work that's already been laid in.

## GC trigger in the allocator (deferred — direct-threading prerequisite)

**Origin:** design-review pass (May 2026, AI-conversation feedback in
`docs/js-design-feedback.md` if archived; conversation referenced
in commits 6026134 / 7f19089 / 4c04fb3).

**The move:** today, `ctx_maybe_gc(ctx)` is called at the top of the
interpreter's dispatch loop in `interpreter.zc`. That places the
threshold check on every opcode. For our current switch-chain dispatch
the cost is ~1 well-predicted cycle per opcode and not the bottleneck.

When we add **direct-threaded dispatch** (computed-goto / `&&` labels
per the design study), each opcode handler has its own dispatch tail
— a central loop-header check no longer fits the architecture. The
canonical move is: trigger GC inside `ctx_register_cell` (the
allocator), since allocation is the only thing that increases
`cells_since_gc`.

**Why not now:** moving the trigger requires that every C-stack cell
pointer held across an allocation be rooted somewhere the GC walks.
We've already audited the host-function paths and added `temp_root`
protection in commit 4c04fb3:

  - `build_typed_error` / `make_named_error`
  - `host_string_concat`
  - `host_array_join`

The remaining gap is **the compiler's `c.constants` buffer**:
freshly-compiled `Function*` cells are added there between their
`ctx_register_cell` registration and their parent's registration.
That buffer is malloc'd, not a GC cell, so the GC root walk doesn't
see it. If GC fired mid-compile (which can't happen today, since the
threshold isn't crossed by typical compile workloads, but is the
trigger condition we'd be enabling), those intermediate functions
would be unreachable and swept.

**The fix when we land it:**
1. Add a per-context "compile in progress" root: a `Compiler*` chain
   accessible from `ctx` (just like `ctx.current_closure`). GC roots
   walk each active compiler and mark its `c.constants` slots and
   any in-flight `Function*` it's holding.
2. Move the threshold check from `ctx_maybe_gc` into
   `ctx_register_cell`, BEFORE adding the new cell to `ctx.cells`
   (so the cell being allocated is safe; only previously-registered
   cells need to be reachable from roots).
3. Delete the `ctx_maybe_gc(ctx)` call at the top of `interpret()`.

Step 1 is the meaningful work — maybe 30 lines plus a careful read of
`compile_function` to confirm there are no other unrooted-mid-compile
hold patterns. Steps 2 and 3 are trivial once step 1 is in place.

**The trigger to pull this forward:** direct-threaded dispatch, or
profiling that shows the per-opcode threshold check is a measurable
fraction of dispatch overhead in real workloads. Until then, current
behavior is correct and the cost is invisible.

---

## Other architectural items deferred

These are noted in phase docs but worth restating in one place:

- **Upvalue-box closures (replacing the env-object model).** The
  current closure model (Phase 3.3) puts captured locals on a heap
  object; reads go through `LoadProp` against the env. Spec-correct
  and IC-cacheable, but adds one indirection vs Lua-style upvalue
  boxes. The rewrite also unlocks multi-level capture for free.
  Trigger: profile workload that shows captured-variable access in
  hot loops as a bottleneck.

- **Direct-threaded dispatch** (computed-goto / `&&` labels). The
  design study targets this. Trigger: once the bytecode shape is
  stable and we want measurable jitless throughput gains.

  *2026-05-13 microbenchmark*: a focused C test of switch-dispatch vs
  computed-goto on a tight numeric loop, compiled `-O3` on Apple
  Silicon, showed **~5% threaded-faster** — much smaller than the
  20-50% commonly cited for older x86. Apple's branch predictor
  handles central indirect-branch dispatch nearly as well as
  per-handler. Our interpreter's per-opcode handler body is also
  substantial (object dispatch, IC probe, GC awareness), which
  further dilutes the dispatch share. Conclusion: threading is real
  but not the lever it once was *on Apple Silicon*.

  **Cross-platform caveat**: zjs is meant to be platform-agnostic.
  Branch-predictor quality varies a lot: older Intel/AMD x86, low-end
  Cortex-A cores (Android, RPi, embedded), and similar likely show
  much larger gains (15-30% range). When we start testing on real
  non-Apple targets, re-run the dispatch microbenchmark there before
  deciding whether to skip threading. The implementation cost
  (rewriting ~900 lines of dispatch) is paid once but pays back on
  every target the engine is ever embedded into.

- **AOT bytecode bundles** (`.zbc` files, Hermes-style). Already on
  the roadmap. Trigger: iOS cold-start workloads where parse cost is
  visible.

- **Arena allocator for cells.** Replaces system `malloc` per cell.
  Trigger: profile showing alloc latency in the engine's hot path.

- **Type-specialized array storage** (int32[] / double[] backings).
  Trigger: numeric-array-heavy benchmark performance gap.

- **Real `eval` runtime.** Currently stubbed. Trigger: real
  workload need; not likely soon.

- **Property descriptors** (`Object.defineProperty`, getters/setters).
  Largest single test262 unlock left in the curated subset (~165
  tests in `Object/create`). Bigger lift — needs a slot-with-metadata
  representation on objects.

- **Wrapper objects** (`new Number(x)`, `new String(x)`,
  `new Boolean(x)`). Today we return primitives. Unblocks ~50 tests
  in expression-operator and built-in-prototype suites.

- **valueOf / toString in arithmetic operators.** Today
  `{valueOf: () => 1} + 1` returns `NaN`. Roughly 30 expression
  operator tests need this.

- **`finally` clause** + **`delete` operator** for `try`. ~40+
  tests in `language/statements/try`.

- **Labeled statements** (`label: while {...; break label; ...}`).
  ~30 tests.

- **Destructuring patterns** in bindings (for-of head, function
  params, var declarators). Sweeping ES6+ feature.

- **Multi-level closure capture.** Today single-level only.
  Likely subsumed by the upvalue-box rewrite.

- **Throw propagation across host→JS boundary.** Today
  `Array.prototype.map`'s callback can't propagate a throw to the
  caller (it gets dropped). Needs a `ctx.pending_throw` field and
  check sites in `Op::Invoke` / `Op::MethodInvoke` after each
  host-function call.

## Follow-ups carried over from the May 2026 feature push

Items deliberately left undone in the recent landings — captured here
so we don't lose them.

### ES modules

- **Live bindings.** Current implementation copies the export value
  into the importer's local at link/eval time; mutations in the
  source module after import don't propagate. Spec semantics require
  imports to be live references — `import { count } from "./a.mjs"`
  followed by an `inc()` from `a.mjs` should see the new `count` on
  the next read. Fix likely needs an indirection through the
  exporter's slot table or a per-import getter cell.
- **Top-level `await`** in module bodies (current parser only allows
  `await` inside an async-function body via `p.in_async`).
- **`export *`** wildcard re-export. Parser doesn't accept it yet;
  runtime needs a "copy all enumerable string keys of source.exports
  except `default`" step.
- **Dynamic `import()`** as an expression — returns a Promise of the
  module's exports namespace.
- **True cycle handling.** Circular imports return the
  partially-populated record; sibling modules see `undefined` for
  not-yet-set names. Spec defines a topological-sort + bind-imports
  phase that supports cycles for non-TDZ accesses.
- **test262 module-flag tests.** Runner skips them — it writes a
  temp-file with the test source and zjs uses filesystem paths for
  relative imports. Either inline-prepend per the spec or
  generate a temp directory and resolve from there.

### async/await

- **`for await ... of`** async iteration. Skipped feature.
- **Async generators.** Skipped feature.
- **Top-level await** (see modules above — same suspend/resume infra
  needs to extend to module bodies).

### Classes

- **Extends + instance fields + no explicit constructor.** Parser
  synthesizes an empty ctor when fields exist without an explicit
  one; fine for base classes but a derived class also needs a
  synthesized `super(...args)` before the field inits run. The
  rest-binding AST synthesis is what's missing.
- **Private fields / methods** (`#name`). Skipped feature
  (`class-fields-private`, `class-methods-private`, plus the static
  forms — together ~3000 tests).
- **Computed-name accessors** (`class { get [k]() {} set [k](v) {} }`).
  Today's computed-method path uses `StoreElem`, which doesn't
  install an accessor pair. Needs a runtime-keyed
  `DefineGetter/Setter` analogue.
- **Class static blocks** (`class { static { /* code */ } }`).
- **`new.target`** in class methods. Skipped feature.

### Iteration protocol / Symbols / generators

- **Real `Symbol`** values with the spec's well-known symbols
  (`Symbol.iterator`, `Symbol.asyncIterator`, `Symbol.hasInstance`,
  ...). Today our string keys coerce a Symbol value to
  `[object Function]`; tests depending on Symbol-keyed dispatch all
  fail.
- **`Symbol.iterator` protocol** wiring on for-of / spread / array
  destructuring so non-array iterables (generators, Maps, Sets,
  user objects) work end-to-end. ~1000 tests skipped on the
  iterator part alone.
- **Generators** (`function* () { yield ... }`) — 1500+ test262
  tests skipped. Suspend/resume infra can reuse the ZjsAsyncCont
  pattern from async/await; `yield` is the equivalent of `await`,
  iterator-result `{ value, done }` envelopes are the public
  surface.

### Destructuring

- **Binding** (`const { a, b } = obj`, `for (const [x, y] of pairs)`,
  `function ({ a, b }) {}`) is in (shipped 2026-05-15 / 16).
- **Assignment** (`[a, b] = arr` as an expression, including LHS member
  targets like `[obj.x, arr[i]] = src`) is still missing. Needs the
  parser's cover-grammar treatment to retroactively reinterpret an
  ObjectLiteral / ArrayLiteral expression as an AssignmentPattern
  on encountering `=`.
- **Array-pattern iterator semantics.** Current impl indexes via
  LoadElem (works for arrays); generators and other iterables need
  the spec's GetIterator + IteratorClose dance. Open: 12+ "iteration
  occurred as expected" test262 failures cluster here.
- **Object-rest computed-key omission.** `let { [k]: v, ...rest } = obj`
  currently omits only statically-named keys from `rest`. Computed
  keys would need a runtime "omit set" tracked alongside the rest
  build.
- **Pattern in `for-await-of`** — same shape as for-of, will land
  with full async-iteration.

### Built-ins

- **`Map` / `Set`** — needed by ~30 for-of tests directly and
  indirectly by many spec-conformance tests.
- **`Date`** — currently a stub.
- **`Object.freeze` / `Object.preventExtensions`** — many
  Array.prototype tests check for the TypeError these should throw.
- **Real `globalThis`** binding — `ctx.global_this_obj` exists but
  isn't registered under that name.

### Operators

- **Optional chaining `?.`** — partial; nullish coalescing operates
  but optional member / call chains still trip on edge cases.
