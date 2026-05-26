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
- **`Symbol.iterator` protocol** is wired everywhere it matters:
  live for-of (2026-05-16), array destructure, Map/Set constructors,
  and the four Promise combinators (2026-05-18, commit cefb846).
  Generators feed any of those uniformly.
- **`IteratorClose` abrupt-completion semantics.** Current
  `iter_close` is "normal-completion" only: a throwing return() from
  the iterator overrides the original completion. Spec says: when
  closing for an *abrupt* completion, the return()-throw is
  swallowed and the original completion re-raised. ~12 test262
  tests in `Array.prototype/map`-style "abrupt-completion-from-cb"
  exercise this.
- **Generators** (`function* () { yield ... }`) — shipped 2026-05-16.

### Destructuring

- **Binding** (`const { a, b } = obj`, `for (const [x, y] of pairs)`,
  `function ({ a, b }) {}`, `catch ([x, y])`) shipped 2026-05-15 / 16.
- **Assignment** as an expression — base cases shipped 2026-05-18
  via the parser's cover-grammar reinterpret (`reinterpret_as_pattern`
  in parser.zc + the object shorthand-with-default carve-out). Open:
  - `for ([ x = 'x' in {} ] of [[]])` — the for-head `in`-
    disambiguator doesn't know `in` is inside a nested expression,
    so it short-circuits to for-in. Needs paren/bracket nesting
    tracking in the for-head pre-pass.
  - `for ({ yield } of ...)` in sloppy non-generator code —
    `yield` should be a valid identifier here; we treat it as
    reserved.
  - Early-error reject for `var o = { x = 1 }` (valid as a pattern,
    invalid as a real object literal). Today we silently accept and
    mis-compile.
- **Array-pattern iterator semantics** shipped 2026-05-16 (uses
  `IterGet` / `IterStep` / `IterClose` opcodes, identical to
  live-for-of). Spec-correct iter.next-result Object check landed
  2026-05-18.
- **Object-rest computed-key omission.** `let { [k]: v, ...rest } = obj`
  currently omits only statically-named keys from `rest`. Computed
  keys would need a runtime "omit set" tracked alongside the rest
  build.
- **Pattern in `for-await-of`** — same shape as for-of, will land
  with full async-iteration.
- **NamedEvaluation edge case.** Anonymous classes that already define
  a static `name` member (`class { static name() {} }`) should NOT
  receive an inferred .name from their binding target. We currently
  overwrite — needs a walk-children check before the StoreProp.

### Built-ins

- **`Map` / `Set`** — shipped 2026-05-16; ES2024/2025 surface
  (`Map.groupBy`, `Object.groupBy`, full Set composition family)
  landed 2026-05-18.
- **`Date`** — basic methods in; locale-aware formatting deferred
  until an Intl pass.
- **`Object.freeze` / `Object.preventExtensions`** — both registered
  but they no-op rather than tracking flags. Many `Array.prototype.push`
  / `pop` tests check that the TypeError fires on a frozen receiver.
- **Real `globalThis`** binding — `ctx.global_this_obj` exists but
  isn't registered under that name.
- **`AggregateError` as a real constructor.** Today `Promise.any`
  builds an Error-shaped object with `name: "AggregateError"` but
  `Object.getPrototypeOf(e) === AggregateError.prototype` fails
  because `AggregateError` isn't a global. ~10 Promise.any tests
  cluster on this.
- **Per-item `C.resolve(value)`** in the Promise combinators. Spec
  says `Promise.all` calls `C.resolve(value).then(onFulfilled, onRejected)`
  per pulled item (where `C` is the combinator's `this`); we
  hand-roll `if (isPromise) item else new + resolve`. ~10 tests
  check the call count.
- **Host-function `.bind`.** `Function.prototype.bind` works for
  closures but returns undefined for host functions, which breaks
  a few Promise / spread combinator tests that try to `cb.bind(...)`.

### Operators

- **Optional chaining `?.`** — partial; nullish coalescing operates
  but optional member / call chains still trip on edge cases.

## Major arcs queued

- **Real `Symbol` values + `Symbol.iterator` protocol made first-class.**
  We currently shim the iteration protocol with string atoms
  (`"@@iterator"`). Real `Symbol` is the largest single conformance
  unlock left in the included subset (~3000 tests across
  class-fields-private, well-known-symbol-keyed property access,
  spec-correct `IteratorClose`). Prerequisite for private class
  fields/methods (`#name`). Phase 4.3 — taken on as the next arc.

- **Private class fields / methods (`#name`)** — follows Symbol
  naturally; same family of test262 unlocks. Skipped today by the
  harness.

- **Property descriptors + accessors as first-class.**
  `Object.defineProperty`, real getters/setters in object literals,
  `Object.freeze` that actually tracks `[[Writable]]` /
  `[[Configurable]]` flags. Today `freeze` no-ops and many
  `Array.prototype.push` / `pop` tests check that the TypeError
  fires on a frozen receiver. Biggest single test262 unlock in the
  `Object/create` subset.

- **GC experiment** — alternatives to the default Hermes-style
  stop-the-world mark-sweep. User-flagged Go's Green Tea GC (cache-
  aware concurrent mark-sweep with minor-pause guarantees) as worth
  exploring; generational nursery, bump-allocator young-gen, and
  deferred refcounting are other points in the design space.
  Hermes's clear daylight on `mandelbrot`, `nbody`, `splay`,
  `object_alloc` points at generational specifically. Bench pause
  time + throughput + footprint before committing.

## Top-level expression-statement `Mov result_reg, r` — single-stmt loop bodies

**The cost:** for `for (...) { sum = sum + i; }` at top level, every
iteration emits `Add sum, sum, i` followed by `Mov result_reg, sum`
to keep the script's completion value updated. The Mov is ~20% of
`int_loop`'s dispatch budget; similar shape in `closure_call`'s outer
loop (`last = inc();`).

**Why it's necessary today:** ECMA-262 §13.7.4 ForBodyEvaluation
tracks V across abrupt completions via UpdateEmpty — so abrupt
completion mid-block (`{ x = 1; continue; }`) must observe the
prior expression's value (1, not undefined). The per-statement Mov
to a fixed `result_reg` is what carries V forward across those
abrupt edges. Naive "skip the Mov, emit one at body bottom" silently
drops the UpdateEmpty value (verified against spec).

**Attempted (and reverted) — TEE-bit side bitset:** mark the IPs of
producing ops with a side-table bit; dispatch loop tail copies
`regs[inst.a]` to `regs[result_reg]` when set. Spec-compliant, but
the per-op check (load bitset + shift + AND + branch ≈ 5 cycles)
exceeds the Mov it replaces in single-statement bodies — the only
shape that actually appears on the hot path of `int_loop`,
`closure_call`, etc. Branch attempted at `perf/expr-stmt-tee-fusion`
(2026-05-26), measured a 28–37% regression on `closure_call` /
`richards`, reverted. Multi-statement bodies WOULD win but aren't
the hot path on any current bench.

**Paths still open (any future poke):**

- **Co-encoded TEE bit in `inst.op`** — steal the high bit of the
  opcode byte; cheaper check (~2 cycles), but requires masking every
  `op == Op::X` compare in the dispatch (≈120 sites) or doubling the
  enum into Op / OpTee variants. Best case is break-even for
  single-stmt bodies, modest win on multi.

- **Smart V-tracker register allocation** — pre-pass identifies the
  dominant V-producing local for hot loops, aliases its register
  with `result_reg` so the assignment writes to V naturally. Zero
  interpreter cost. Fragile around multiple V-trackers, captured
  locals (live in env, not registers), and conditional flow — needs
  scope-aware analysis.

- **Direct-threaded dispatch + per-op completion hook** — once we
  move off switch-chain dispatch (the AOT phase), the TEE check
  could fold into the tail of each opcode's handler instead of a
  shared loop tail. The per-op overhead amortizes because there's
  no central branch to skip.

None of these are urgent — the spike's env-reg cache already pushed
`closure_call` from 5× to 2.3× behind Hermes, which is where most
of the realizable single-Mov-elimination perf lives. Document the
gap and move on.

## iOS xcframework — landed (2026-05-26)

`make ios-all` produces `build/ios/zjs.xcframework` bundling
`libzjs.a` for arm64 device + arm64/x86_64 simulator. Drop into
Xcode, link Foundation + CoreFoundation, `#include "zjs.h"`. See
`docs/ios.md`. Standalone — no zapp dependency.

The original Phase 0.5 plan called for porting zapp's multi-stage
`_zapp_build_ios.zc` overlay. We didn't need to — the right move
was to skip zc's `--cc` plumbing on iOS entirely and drive
`clang` directly from the Makefile (which already had the same
shape for the macOS `libzjs.a` target). Documented in
`docs/cross-compile.md`.

## Major arcs landed

Kept here for context — these were once on this list and are now
either fully shipped or in a stable state with their own ongoing
maintenance threads.

- **Cross-compile sweep** — Apple SDK paths via `xcrun`, Windows
  WinHTTP / BCrypt / Psapi shims, Linux POSIX shims. Live status in
  `docs/platform-port-status.md`. The `zig cc` cross-compile to
  non-Apple targets has a known issue (#206) — Foundation directive
  leaks across compiler hosts — but the native-toolchain build works
  on each platform.

- **Runtime layer (`zjs-runtime`)** — the txiki-style batteries
  shipped across Phases A–E (timers, console, performance, atob/btoa,
  `TextEncoder` / `Decoder`, `crypto.getRandomValues` / `crypto.subtle`,
  `URL` / `URLSearchParams`, `fetch` (sync + async, HTTP/HTTPS),
  `Response` / `Headers`, `WebSocket` over `NSURLSessionWebSocketTask`
  on Apple, sync HTTP via WinHTTP on Windows). Linux native HTTP /
  WebSocket backends (#201, #205) remain stubbed pending libcurl /
  libwebsockets work.
