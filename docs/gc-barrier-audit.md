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

2. ☐ **OPEN — async/promise object graph.** The async *pipeline* still ASan-
   UAFs: a young Promise (from `Promise.resolve` in an `await` loop) is freed by
   a minor while still referenced by an OLD cell 3 hops from a root
   (object → … → promise → freed promise). Suspects (deferred edges from the
   audit's "verify" list): host-fn **`.bound`** stores in the Promise machinery
   (~20 sites: resolve/reject/job/combinator fns bound to young state), and
   Promise.all/race **state objects** holding young element promises. These are
   old→young edges with no barrier. NOT yet root-caused (only repros under the
   sustained pipeline; test262 async tests are too short to promote+free).

**Status: correct for sync + test262 (incl. all async tests, 0-new) + ASan-clean
on non-pipeline workloads; one OPEN async-pipeline UAF remains. Behind
ZJS_GEN_GC (default OFF) — NOT real-app-safe for sustained async until #2 is
closed. Default untouched (88.1%, 0 reg). Perf: object_alloc −68%/−79%, splay
max −27%.** Next: barrier the host-fn `.bound` + Promise-combinator-state edges
(or a targeted "scan promise/cont graph" approach), re-soak the pipeline under
ASan to 0-UAF, then the broader soak + default-on decision.
