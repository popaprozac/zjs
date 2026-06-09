# Perf architecture review — closing on Hermes, distancing QuickJS (2026-06-09)

Scope: structural review of the interpreter + GC against Hermes (the jitless
North Star) and QuickJS (the engine we want to stay ahead of). Grounded in the
2026-06-08 `sample` profile (alloc-heavy driver, default GC: dispatch 36%,
property-define ~20% → fast-define shipped `64742aa`, malloc churn ~19%) and a
three-way code audit (interning model / interpreter hot paths / GC + heap).

## Where zjs already matches the class leaders

These are NOT gaps — don't re-litigate them without a profile saying otherwise:

- **Value representation**: JSC-style NaN-boxing (`value.zc:1-50`), doubles
  immediate, int32 a distinct immediate with int-first arithmetic fast paths.
  Same design class as Hermes.
- **Inline caches**: 4-way polymorphic LoadProp/StoreProp with own-slot and
  direct-proto caching (`interpreter.zc:6014-6269`). Hermes-class for mono/poly
  sites.
- **Globals**: O(1) slot-indexed (`GlobalEntry`), same as Hermes.
- **String concat**: lazy ropes with flatten-on-access + cached flat. QuickJS
  concatenates eagerly — we're ahead here.
- **Dispatch**: if/else chain that clang -O3 + thin-LTO lowers to a single
  indirect branch (whole engine is ONE translation unit via `zc transpile`, so
  cross-file inlining works). Measured: direct-threading is a null win.
- **Call frames**: conditional arg copy (skips when `arguments`/rest unused,
  ≈3% on fib), in-place push. The remaining per-call fields (outer_promise,
  generator, realm) are load-bearing (GC roots / multi-realm) — T1.3 slim-frame
  was DESCOPED: the skippable stores are ~3, sub-noise.

## The ranked gaps

### Tier 1 — surgical, this branch

**T1.1 — interned-atom pointer equality in `zjs_string_equals`** (#376)

`class_find_slot` / `class_find_transition` call `zjs_string_equals` per chain
step; same-length misses fall through the `a == b` check to a `memcmp` CALL
(~4.7% of the post-fast-define profile: `_platform_memcmp` 419 + stub 128
samples). Fix: after the pointer check, `if a.interned && b.interned return 0`.

Safety argument (audited 2026-06-09): `interned = true` is written in EXACTLY
one place — `atom_table_insert_unchecked` (context.zc:2640) — and every entry
point (`ctx_intern_atom` / `_no_decode` / `_take`) does lookup-before-insert
into the per-context table (atoms are never shared across contexts; realms
share one table by design). Rope flatten (value.zc:2988), `ctx_intern_string*`,
and `zjs_string_new_take` (value.zc:3147) all set `interned = false`; the AOT
loader interns via the dedup path (aot.zc:217). Therefore two live strings with
`interned == true` and equal bytes are ALWAYS the same pointer — the guard can
never produce a false "not equal". Non-interned keys (e.g. `zjs_to_string`
results reaching class_find_slot via interpreter.zc:207/1829/1879) fall through
to memcmp exactly as today — correct, just not accelerated. Transition names
are always atoms (object_set / object_define_property_slot intern at entry), so
the hot compiled-key path compares interned-vs-interned and takes the new exit.

DESCOPED with it: T1.2 cached string hash (ctx_intern_atom was 0.7% of the
profile — sub-noise) and T1.3 slim call frame (fields are GC-read per mark
since the #375 frame.generator fix; must stay initialized).

**T1.4 — property_get tag-dispatch order** (DEMOTED to profile-gated)

The review flagged that `property_get`'s exotic dispatch (interpreter.zc:236+)
checks ~14 tags before `TAG_OBJECT`. BUT the head was already tuned: the tag is
hoisted to one u8 load (line 236) and the in-tree comment records a MEASURED
17-23% recovery from that change, with clang lowering the compare chain to a
near-jump-table — so branch ORDER is likely immaterial. Classic clang-does-more-
than-intuition territory. Do NOT implement blind; only revisit if a post-T2.1
profile shows property_get's dispatch head (not its lookup body) hot.

### Tier 2 — the architectural gap (the Hermes/QuickJS divider)

**T2.1 — per-shape property table** (#377)

THE structural gap vs BOTH engines. `class_find_slot` (value.zc:3278) is a
linear parent-chain walk — O(prop_count) per lookup with a string compare per
level, no dictionary fallback at ANY size. A 300-prop object linear-walks 300
classes; reading the first-added property of an 8-prop object costs ~7 levels.
Hermes keeps a per-class DictPropertyMap; QuickJS keeps a hash table per shape.
We have neither — this is a place where we're behind QuickJS, not just Hermes.

Design: attach a lazily-built open-addressed table (interned-atom ptr → slot)
to `ZjsHiddenClass`, built on first lookup once `prop_count >= ~8`; consult it
in `class_find_slot` before the chain walk. Key by pointer (T1.1's invariant
makes atom pointers canonical; intern the lookup key at the boundary when
non-interned). Invalidation is trivial: classes are immutable after creation
(transitions create children), so the table never goes stale; build it once per
class, free it with the class. Fixes deep shapes, megamorphic sites, AND the
property_get miss path in one move. Sequence AFTER T1.1.

Expected: the agent review estimates 3-5× on property-heavy slow paths;
realistically benchmark-visible on property_poly / wide-object workloads,
neutral elsewhere. Gate: bench suite + test262 0-reg + ASan Y=64 (the table
holds atom pointers — atoms are GC cells; ensure the class's table entries
don't outlive atoms, or mark table keys via gc_mark_hidden_class like
transition_name... NOTE transition_name is deliberately NOT marked (pinned
atoms); table keys are the same atoms — same invariant, no new marking).

**T2.2 — megamorphic IC backstop** (new, after T2.1)

Once a site sees a 5th shape, `megamorphic=true` is permanent and every access
takes the full property_get slow path (interpreter.zc:6117). Hermes keeps a
global (class, name) → slot cache as a backstop. With T2.1's per-shape table,
the slow path itself gets much cheaper, so measure AFTER T2.1 — a separate
megamorphic cache may become unnecessary. Only build if property_poly still
lags.

### Tier 3 — structural GC/alloc (own project, parked)

From the GC review, in descending value:

- **T3.1 nursery bump-allocation**: 1-3 mallocs per object / 2 per array+string
  vs Hermes's single bump-pointer alloc. The ~19% malloc-churn profile bucket.
  Requires a real slab over cells + element/string buffers (the 2-frees-per-
  array churn — object-CELL pooling alone was a validated null win). Natural
  home is the ZJS_GEN_GC nursery. Big, corruption-risky, own session.
- **T3.2 gc_nullify_dead_ics cost**: O(live functions × ICs) every major.
  Could mark IC-referenced classes instead (trade: keeps dead shapes alive one
  cycle). Only matters on script-heavy heaps; profile first.
- **T3.3 incremental/concurrent marking**: Hermes Hades does concurrent old-gen
  marking; we're stop-the-world. The opt-in generational minor already cut max
  pause 28%; concurrency is the next pause lever but a major project.

## Sequencing

1. T1.1 (this branch, now) → 2. T1.4 (same session if green) → 3. T2.1 (the
headline; next focused push) → 4. measure → T2.2 only if still needed → 5. T3.x
as a dedicated future project alongside the ZJS_GEN_GC default-on decision.

Validation gate for every step (unchanged): build, targeted microbench BEFORE
committing (null-win discipline), bench suite compare, default test262 0 new
failing paths, ASan ZJS_GEN_GC=1 YOUNG=64 soak on the touched paths.
