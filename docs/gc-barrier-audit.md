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
2. ☑ `.props` expando attach → `ctx_new_props_bag` (old-gen alloc) + proto (setPrototypeOf) + generator-pending.
3. ☐ Remaining sweep: host-fn `.bound` (mostly young-holder — verify), user `.prototype` writes (property_set), interpreter setPrototypeOf/`__proto__` paths, splice-insert, WeakMap/WeakSet add.
4. ☐ `ZJS_GEN_GC` flag in `ctx_maybe_gc` → `gc_run_minor` on young fill (default OFF).
5. ☐ Soak: splay no-hang, full test262, alloc-churn, Promise/embedded-worker; tune nursery threshold.
