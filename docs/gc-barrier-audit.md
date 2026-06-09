# Write-barrier coverage audit (2026-06-08, branch `perf/gc-alloc-path`)

Goal: re-enable the gated-off generational **minor** collector (see
`docs/gc-experiment.md`). The minor sweep frees/recycles only the young
nursery and re-scans roots + the **remembered set** (old cells that hold a
pointer into the nursery). A young cell is reclaimed unless a root or a
rem-set entry keeps it live. **A missing write barrier on an old→young
store = use-after-free** (the minor frees a young cell an un-scanned old
cell still references). Session 3 hung splay for exactly this reason.

## The rule

`gc_write_barrier(ctx, holder, value)` records `holder` into the rem-set
**iff** `holder` is old (`age != 0`) and `value` is a young cell. So a
barrier is *needed* only where a **possibly-old** heap cell's pointer
field is mutated to reference a **possibly-young** cell. It is a cheap
no-op for young holders, non-cell values, and old→old edges — so when in
doubt, adding one is safe.

**Behavior-neutral while the minor trigger is OFF:** the rem-set is only
consumed by `gc_run_minor`, and `gc_run_major` resets `rem_count`. So we
land barrier coverage incrementally with the minor still gated off (zero
behavior change, zero test262 delta), and flip `ZJS_GEN_GC` on only after
coverage is complete and soaked.

## NOT barrier-relevant (eliminated from the audit)

- **Register stack** (`regs[...]`, `ctx.reg_stack[...]`), **`ctx.frames[].*`**,
  **`ctx.realm.globals[].value`** — these are GC **roots**, scanned in
  full on every minor (`gc_mark_roots`). No barrier.
- **Stores at/just-after cell creation** (`ctx_new_object` proto, `ctx_new_array`
  proto, generator `saved_regs`/`saved_*` at spawn, closure `captured_this`
  at spawn) — holder is young; barrier no-ops AND young holders are
  re-scanned at promotion. No barrier.
- **`zjs_deleted()` / `zjs_undefined()` / `zjs_null()` / non-cell stores**,
  **`NULL` proto stores**, **string `r.flat`** (points at a string, but a
  rope is young when flattened / its parts are reachable) — barrier no-ops.
- **Realm/bootstrap init** (`src/context.zc` ~27000–30200) — one-shot at
  context creation; everything co-young then co-promotes. Harmless to skip.
- **In-place permutation** of existing array elements (`sort`, `reverse`
  swaps) — moves values already reachable from the array; no NEW edge.

## NEEDS a barrier (the real coverage list)

Status: ☑ done · ☐ todo

### Object slot writes (old object ← young value)
- ☑ `object_set` / `object_set_internal` (context.zc ~2885/2913/2918) — already barriered.
- ☐ `object_define_property_slot` (context.zc ~2949, ~2964) — used by InitObjData, defineProperty, `species_def_slow`. **GAP.**
- ☐ `Op::StoreProp` IC fast path (interpreter.zc ~6193 `o.slots[slot_n]=value`). **HOT GAP.**

### Array element writes (old array ← young value, NEW edge only)
- ☑ `array_set` (value.zc ~3625) — already barriered.
- ☐ `Op::StoreElem` fast path (interpreter.zc ~6404/6407 `arr.elements[u]=value`). **HOT GAP.**
- ☐ `splice` inserted args (context.zc ~10752/10809/10814).
- ☐ spread-into-array / Op::AppendSpread direct writes (interpreter.zc ~6308/7759), arguments-object fill (~7554/7570) — verify holder age (often young).

### Prototype pointer (old object ← young proto)
- ☑ `object_set_prototype_of` store (`o.proto = new_proto`) barriered.
- ☐ interpreter.zc setPrototypeOf path (~5675) + object_set `__proto__` (~4782) — verify/cover next batch.
- ☐ subclass proto wiring on existing ctors (context.zc ~28368/29491 — bootstrap, likely safe).

### Expando bag `.props` (old cell ← young bag object)
- ☑ SOLVED structurally, not per-site: `ctx_new_props_bag` allocates the bag
  directly in **old-gen** (age=1), so the holder→bag edge is never
  old→young and needs no barrier. Converted all 46 runtime `property_set`
  attach sites (interpreter.zc 25 + context.zc 21) from `ctx_new_object`.
  The 3 compiler.zc sites stay young (compile-time holders are young, re-
  scanned at promotion). The bag's own slot writes are barriered via
  object_set / object_define_property_slot.

### Host-function binding (`.bound`, `.prototype`)
- ☐ `hf.bound = state_v` (Promise/Proxy/bound-fn machinery; interpreter.zc ~4282; context.zc ~12439–24600) — host-fn may be old, state young.
- ☐ `hf.prototype = ...` / `f.prototype = ...` user writes (interpreter.zc property_set ~1029–8206; context.zc ~22109/23014) — non-bootstrap.

### Promise / async / generator
- ☑ `promise.reactions` / `promise.value` (context.zc ~12311–12340) — barriered.
- ☑ generator `pending_next_promise` (async-generator resume) barriered.
- ☐ async-continuation saved state if the cont cell can be old (interpreter.zc ~4313–4319) — usually young; verify.

### Map / Set
- ☑ `map_set` / `set_add` value+key (context.zc ~12787/12793/13121) — barriered.
- ☐ Map/Set entry-array realloc keeps pointers; the add path barrier covers new edges — verify WeakMap/WeakSet add paths.

## Execution
1. ☑ Choke-point barriers: object_define_property_slot, StoreProp IC, StoreElem (eab0ee3).
2. ☑ `.props` expando attach → `ctx_new_props_bag` (old-gen alloc) + proto (setPrototypeOf) + generator-pending (5f46a57).
3. ☑ `ZJS_GEN_GC` flag (+ `ZJS_GEN_GC_YOUNG` threshold override) in `ctx_maybe_gc` → `gc_run_minor` on young fill; **default OFF**.
4. ◐ First soak (ZJS_GEN_GC=1, aggressive minors `YOUNG=64..256`):
   - ☑ **splay no longer HANGS** (the Session-3 blocker — fixed by the object-slot + proto barriers). exit 0.
   - ☑ all 24 microbenches run clean under aggressive minors.
   - ☐ full test262 under the flag: **202 NEW failures** vs default (default itself unchanged: 88.1%, 0 reg). Remaining barrier gaps, clustered: `Object.defineProperty` / `defineProperties` (~120), `Object.create` (~5), `Array.from` / `Array.prototype.with`. These store a young value into an old (often exotic: `arguments`, array-index) holder via a define path that bypasses object_define_property_slot. NOT yet root-caused per-cluster (only repro under the full harness).
5. ☑ **Closed all 202 — single root cause (ASan).** The freed cell was a
   `ZjsHiddenClass`: the shape-graph **transition tree** (`class_add_transition`
   stores child→parent.transitions) is an old→young pointer edge that is NOT a
   ZjsValue, so no barrier covered it and the audit missed it. A minor freed a
   live transition class out from under its parent → heap-use-after-free in
   `object_set`/`getOwnPropertyDescriptor`. **Fix: pin the shape graph in old-gen**
   (`ctx_register_cell_old` for transition classes, the 2 sites in
   object_set / object_define_property_slot) — mirrors atoms + props-bags.
   Re-soak under ZJS_GEN_GC: **202 → 0 NEW** failures; default still 88.1% / 0 reg;
   splay + all benches clean.

## CORRECTNESS DONE + minor made O(young) (perf)

Minor-efficiency fix (the O(old)-per-minor mark-clear): in minor mode neither
`gc_mark_value` nor `gc_mark_hidden_class` marks old cells (short-circuit BEFORE
setting the bit — old cells are never swept by a minor); `gc_sweep_young` clears
the mark on each promoted cell; the O(old) clear loop + the redundant rem-set
`rh.mark=1` + the minor's `gc_nullify_dead_ics` (classes are old-pinned → never
die in a minor) are all removed. ASan-verified clean (dp_repro / churn / splay).
**Gotcha that bit once:** removing the clear loop requires reordering BOTH mark
functions — leaving `gc_mark_hidden_class` marking old classes left stale marks
a later major misread as visited → freed live classes (bootstrap UAF).

Measured (`--gc-stats`), default vs ZJS_GEN_GC:
| bench | metric | default | gen | |
|---|---|---|---|---|
| object_alloc (churn) | total pause | 1.93 ms | **0.62 ms** | −68% |
| object_alloc | max pause | 0.14 ms | **0.03 ms** | −79% |
| splay (huge live set) | max pause | 13.6 ms | **9.95 ms** | −27% |
| splay | total pause | 20 ms | 34 ms | (minor overhead) |

Generational is a clear win where garbage dominates (object_alloc); modest on
splay, which is live-set-bound (a major still must mark the 1.4M-cell tree —
generational can't make a live set smaller). Minor is now genuinely O(young).

## Broader real-app soak (2026-06-08) — found 2 MORE async/suspend gaps

A sustained self-checking stress (`/tmp/realapp_soak.js`: tree/class/Map/Set/
closure/defineProperty/JSON/array-species/generator churn + a deep async
Promise pipeline) under ZJS_GEN_GC + ASan surfaced gaps test262's short tests
miss. Synchronous half: GEN_GC == default, all pass. Async half exposed UAFs:

1. ☑ **FIXED — generator / async-cont saved_regs.** On a *re*-suspend (later
   yield/await), a generator/continuation already promoted to old re-saves
   young regs (e.g. a freshly-awaited Promise) into saved_regs with no barrier
   → minor frees the awaited Promise → UAF. Fix: `gc_barrier_cell(holder)` (adds
   an old holder to the rem-set once, re-scanning all its slots) at every
   suspend save site — Op::Yield (start + yield), async-gen await, async-fn
   await. ASan-clean now on dp_repro / gcstress / the defineProperty cluster.

2. ☑ **FIXED — async-cont / generator `.function` was never marked.** Both the
   TAG_ASYNC_CONT and TAG_GENERATOR mark branches skipped `.function` with a
   stale comment ("owned by the context's function registry — no mark needed").
   That's false under generational GC: a runtime-compiled function value (an
   `async function` expression) is a young GC cell referenced only via the
   cont/gen, so a minor frees it and `push_call_frame` reads freed memory on
   resume. Fix: mark `.function` in both branches (the closure branch already
   does for `cl.function`). ASan-clean now on async_a (await-Promise.resolve
   pipeline) AND async_b (Promise.all/race churn) in isolation.
3. ☑ **FIXED — `g_active_ctx` was not set during async/generator RESUME.**
   The "interleaved-async Promise UAF" was NOT a missing barrier on a promise
   edge — it was the *barrier itself silently no-op'ing*. The param-less write
   barrier (`gc_barrier(holder, value)` in `value.zc` `array_set` etc.) reads
   the **global `g_active_ctx`** to find the rem-set. `interpret`/`interpret_inner`
   set it via `gc_set_active_ctx`, but the resume entry points
   `interpret_resume_generator` and `interpret_inner_resume` called
   `interpret_inner_full` **directly without setting it**. So every array/object
   write executed *inside resumed async/generator code* ran with a stale/NULL
   `g_active_ctx` → the barrier returned early → an old holder that gained a
   young child during resume was never added to the rem-set → the next minor
   freed the live young cell (UAF). Only reproduced in the combined soak because
   it needs (a) a holder already promoted old and (b) a young store happening
   *during resume*, not the initial run. Instrumentation (a save/restore'd
   "current holder" fingerprint in `gc_mark_value`) pinned the freed cell's
   holder to an old ARRAY mutated inside the awaited pipeline — confirming the
   write path, not the mark path, was at fault. **Fix: wrap both resume entry
   points with `let s = gc_set_active_ctx(ctx); … gc_set_active_ctx(s);`** so the
   param-less barrier fires during resumed code. This is a genuine latent
   correctness landmine — harmless under default major-only GC (no rem-set
   consulted), fatal under minor GC. ASan-clean now on **all** repros
   (realapp_soak / async_a / async_b / dp_repro / gcstress) under
   `ZJS_GEN_GC=1 ZJS_GEN_GC_YOUNG=48`.

**Status: CORRECT + real-app-safe under ZJS_GEN_GC at the default threshold.**
Sync + full test262 (incl. all async tests) byte-identical failure set vs default
(0-new under the flag at Y=1024); ASan-clean across every soak repro under
aggressive minors; default untouched (88.1%, 0 reg). Perf: object_alloc
−68%/−79% total/max pause, splay max −28% (14.9→10.7 ms — the iOS-relevant
latency metric), at the cost of higher total minor overhead on live-set-bound
workloads (splay 22→36 ms).

## `young_threshold` tuning (2026-06-08)

The minor trigger (`ctx_maybe_gc`: fire a minor once `cells_since_minor >=
young_threshold`) had a latent knob bug: `gc_run_minor` reset `young_threshold`
to a hardcoded literal `1024` after every collection, so `ZJS_GEN_GC_YOUNG` only
affected the *first* minor and then snapped back. Fixed with a persistent
`young_threshold_base` (init 1024, set from `ZJS_GEN_GC_YOUNG`); the reset now
reads the base, so the knob is honest for the whole run. Added a minor/major/
promoted breakdown to `--gc-stats` for measurement.

Sweep (best-of-3, `--gc-stats`), splay (live-set-bound) and object_alloc
(garbage-dominated):

| Y      | splay max | splay total | splay rss | object_alloc total | object_alloc max |
|--------|-----------|-------------|-----------|--------------------|------------------|
| 256    | 16.2 ms   | 49.9 ms     | 152 MB    | 0.82 ms            | 0.03 ms          |
| 512    | 13.5 ms   | 41.7 ms     | 160 MB    | 0.68 ms            | 0.03 ms          |
| **1024** | **9.0 ms** | **31.1 ms** | 160 MB  | **0.61 ms**        | 0.03 ms          |
| 2048   | 10.0 ms   | 32.8 ms     | 160 MB    | 0.53 ms            | 0.03 ms          |
| 4096   | 10.7 ms   | 34.1 ms     | 160 MB    | 1.24 ms (degrades) | 0.06 ms          |
| 16384  | 11.1 ms   | 34.6 ms     | 161 MB    | 1.78 ms (≈major-only) | 0.14 ms       |
| default (major-only) | 13.3 ms | 18.5 ms | 171 MB | 1.67 ms | 0.13 ms |

Clear **U-shaped optimum at 1024**: below it both pauses blow up (too-frequent
minors re-scan roots + a growing rem-set on the big mutated tree); above it the
nursery-reclaim win on garbage-heavy code fades back toward the major-only path
(object_alloc regresses by Y=4096). Wall-clock: splay +6% (the live-set marking
cost), object_alloc −11% (cheaper nursery reclaim, less malloc churn),
compute-bound (nbody/mandelbrot/json) ±1% noise. The original "adapt threshold
upward with old-gen size" intent measures strictly worse, so the trigger stays a
**fixed base of 1024** — confirmed optimal, kept as the default.

## Aggressive-minor UAF sweep (#375) — root unrooted C-locals across user code

Now that `ZJS_GEN_GC_YOUNG` is honest, an aggressive soak (`Y=64`, full test262
under ASan) surfaced **250 NEW failures vs default — all real heap-use-after-free**.
The unifying root cause was NOT "missing write barriers" but **unrooted C-locals /
fields held live across a call into user JS** (or an allocating helper): the
interpreter's register file + `temp_roots` + frame fields are the GC roots, and
anything a native/interpreter routine holds only in a C-local while a minor can
fire is freed. Five fixes took 250 → 55 (78%), 0 default regressions:

1. **`group_by_walk` (Object/Map.groupBy)** — root the iterator + accumulator +
   current element across the callback (`ctx_push_temp_root` + per-iteration
   `ctx_replace_top_temp_root`). The freed cell was the `ZjsArrayIter`.
2. **`object_define_property_slot` intern choke-point** — a computed-key define
   (`class { [x||1](){} }`, `{ [k]: v }`, computed get/set, computed fields)
   stored a fresh young, non-interned key as the hidden-class transition_name,
   which `gc_mark_hidden_class` deliberately doesn't mark → minor frees the key →
   UAF in `class_find_slot`. Fix: intern to a pinned atom at entry (mirrors
   `object_set`; the interned-flag guard keeps the already-atom hot path free).
   Cleared the whole `cpn-class` / computed-property cluster.
3. **`host_array_from_static` (Array.from)** iterable branch — root iterator +
   current yielded value across the mapFn callback.
4. **`Op::IterRestCollect`** (array-destructuring rest `[...r] = iter`) — the rest
   array was a C-local written to a register only AFTER the collection loop;
   `iter_step` resumes a generator (→ minor) → the in-progress rest array is
   freed. Root it + the current element (explicit push/pop — `defer` is
   function-scoped and the interpreter is one big function).
5. **`gc_mark_roots` missed `frame.generator`** + **TAG_GENERATOR mark walked a
   NULL `saved_regs`.** A generator-function call sets `frame.generator = gen`
   then runs the param-default + destructuring PROLOGUE, which can execute user
   code (a computed default, or a custom-iterator `[Symbol.iterator]()`); the
   young generator is reachable ONLY via `frame.generator` until
   `Op::GeneratorStart` captures it → a minor frees it. Fix: mark
   `frame.generator` (NULL on non-generator frames). That exposed that a
   `GEN_STARTING` generator has `reg_count` set but `saved_regs == NULL` (regs
   still in the active frame), so the TAG_GENERATOR mark walk segfaulted — guard
   it with `saved_regs != NULL`. Cleared the ENTIRE `language/.../dstr` cluster
   (generator/class/object param destructuring).

**Method that worked every time:** aggressive `Y=64` ASan soak → minimal repro
churning the construct → read the ASan free/alloc/use stacks (the freed cell's
allocator pins the exact unrooted local) → root it. The previously-fixed soak
repros stay ASan-clean throughout. At the default 1024 these all pass (test262's
allocations are small), **but the gaps are threshold-independent in principle** —
allocation-heavy user code can trip them even at 1024 — so closing them is real
robustness, and gates the **default-on** decision.

**REMAINING ~55 at Y=64 (the long tail, smaller scattered clusters):** Promise
combinators (`all`/`allSettled`/`any`/`race`/`try` — the per-iteration
`item`/`per_state_v`/element rooting deferred from fix 3's sibling),
`Set.prototype` set-ops (`difference`/`intersection`/… iterator rooting), plus
scattered `Object.defineProperties`/`keys`, `JSON.stringify` array-replacer,
`Proxy.ownKeys`, `Function.prototype`. Same method applies; next increment.
