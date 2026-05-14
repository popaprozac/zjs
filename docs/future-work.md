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
  but not the lever it once was. The work cost (rewriting ~900 lines
  of dispatch in raw C inside one Zen-c function, or splitting into
  N tail-called handlers) is high vs the expected ~5% ceiling.
  Reconsider only after (a) frame-reuse / non-recursive interpreter
  closes the fib-style call gap, OR (b) we move to a 4-byte
  packed-per-opcode encoding (Hermes-style) where dispatch becomes
  a larger share again.

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
