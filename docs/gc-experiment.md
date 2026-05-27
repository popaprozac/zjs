# GC experiment — design notes (2026-05-18)

Baseline: today's GC is a stop-the-world mark-sweep keyed off allocation
count (`cells_since_gc >= gc_threshold`, threshold = `2 × live` after
each collection, floor 256). Roots come from registered cell array,
globals, interpreter root frames, temp roots, pending throw. Sweep
walks the flat `ctx.cells` array, frees unreachables, compacts the
array.

It's simple, correct, and works. The question this doc tries to
answer: **what's the highest-leverage change that's worth the
complexity?**

## Where it hurts

Instrumentation landed in commit `5efe634`. Baseline on
`scripts/bench/*.js`:

| Bench         | Runs | Total pause | Max pause | Freed   | Live (final) |
|---------------|-----:|------------:|----------:|--------:|-------------:|
| **splay**     |    7 |  **28.9 ms**| **18.7 ms** | 266 K | **1.4 M**    |
| object_alloc  |   71 |   2.21 ms   |  0.08 ms  | 99 K    | 1.4 K        |
| json_roundtrip|    6 |   2.43 ms   |  0.60 ms  | 152 K   | 27 K         |
| regex_match   |    1 |   0.08 ms   |  0.08 ms  | 2.8 K   | 1.7 K        |
| *17 others*   |    0 |   —         |  —        | —       | 0.7 – 4 K    |

Two things stand out:

1. **17 of 21 microbenches never trigger GC at all.** They're tight
   integer loops that allocate fewer than 4 K cells. Whatever
   collector we add can't move the needle here — and that's fine,
   the existing collector is invisible.
2. **splay is the worst-case profile.** 1.4 M live cells, single
   pause as long as 18.7 ms. That pause is the *mark* phase walking
   all live cells. The 266 K cells we free are a small fraction of
   the heap; most of splay's work is keeping its tree alive across
   collections.

The other GC-touching benches (object_alloc, json_roundtrip) have a
"lots of short-lived garbage, small live set" profile — the classic
nursery sweet spot. object_alloc's 71 minor pauses average 31 µs;
those are fine in absolute terms, but bump-allocator + minor-only
collection would tighten the allocation path noticeably.

## Options

### A. Generational + bump-allocator nursery — *recommended*

- New cells go into a fixed-size **young generation** (bump allocator;
  e.g. 1 MB / ~30 K cells).
- A **minor GC** runs when the nursery fills. It walks roots + the
  remembered set, copies survivors out into the old-gen (or
  promotes after N survivals), resets the bump pointer.
- The **old generation** is the existing flat `ctx.cells` array +
  mark-sweep. Major GCs fire only when old-gen pressure is real,
  much less frequently.
- A **write barrier** records old → young pointer stores into a
  remembered set so minor GCs find them as roots.

**Wins on the bench profile:**
- splay's 18.7 ms major pause becomes one major every N minors,
  with minor pauses scaling with *new* allocations only — under
  1 ms each.
- object_alloc's 71 mark-sweep minors become 71 minor-GC scans of
  the nursery — order-of-magnitude cheaper.
- json_roundtrip similar.
- Allocation hot path becomes a pointer bump (a few ns) instead of
  free-list walk.

**Costs:**
- Write barriers on every Op::StoreProp / Op::StoreElem /
  Op::StoreGlobal / mutable closure slot. Existing code paths
  need careful audit.
- Remembered set (a set of (cell, slot) pairs) needs an efficient
  representation — open-addressing hash table is fine.
- Promotion logic (when does a young cell graduate?). Typical:
  promote on second minor that finds it live, or always-promote on
  copy.
- Header bit for `cell_is_young` — we have spare tag bits.

**Scope:** ~3 sessions of careful work + a robustness pass against
the test262 suite.

### B. Incremental mark — *partial win*

- Same single-generation collector, but mark in fixed-size chunks
  between allocations (or between bytecode instructions).
- Pauses cap at "chunk size × walk cost"; total throughput similar
  or slightly worse.

**Wins:**
- splay's 18.7 ms cap becomes whatever we set (e.g. 1 ms).
- Same total work, just distributed.

**Costs:**
- Write barriers (different shape: track pointers modified
  *during* an in-progress mark so the marker doesn't miss them).
- State machine for "marking", "between marks", "sweeping".
- No throughput win — actually slightly worse because of the barrier
  overhead.

Worth doing eventually for UI-thread workloads in `zapp`; not the
right first move because it doesn't improve throughput.

### C. Concurrent mark-sweep (Green Tea style) — *too much for now*

- Mark on a separate thread, mutator runs concurrently with brief
  STW barriers.
- Effectively zero observable pauses.

**Costs:**
- zjs's interpreter isn't thread-safe today (no atomics on the
  cell list, hidden-class chain, etc.). Making it thread-safe is a
  separate, larger architecture change.
- Bench profile doesn't justify the cost yet — splay is the only
  bench with pauses you'd notice on an interactive UI thread, and
  generational already buys most of that win.

Worth revisiting after generational lands and `zapp` workers reach
sustained sub-millisecond timing budgets.

### D. Tune the threshold — *no real win*

Lower the GC threshold from `2× live` to a constant cap (e.g. `min(2×
live, 200 K)`). Splay would GC every 200 K allocs instead of every
2.8 M.

**Why it doesn't work:** every GC still walks all 1.4 M live cells.
Throughput drops (more GCs); per-GC pause unchanged. The cells-live
walk is the cost; you can't get out of it without segregating young
from old.

## Recommendation

**Generational + bump-allocator nursery** (option A). The bench
profile shows the exact case it was designed for: a workload with a
large persistent live set plus a stream of short-lived allocations.
splay is the smoking gun; object_alloc is the supporting case;
nothing in the bench set would regress.

Scope is real (multiple sessions), but the design is well-trodden
(V8, JSC, Hermes, even SpiderMonkey all converged on it before
adding anything fancier), and our heap shape — flat cell array + a
small set of cell types with statically-known field layouts — makes
write barriers straightforward.

## Proposed execution plan

**Session 1 — design + scaffolding (done as part of this doc).**
- This doc (✓).
- Write-barrier audit: enumerate every spot in the codebase that
  stores a `ZjsValue` into a heap-resident slot. Produce a checklist.
- Tag-bit reservation: pick the bit in `CellHeader` we'll use for
  `is_young`.

**Session 2 — nursery + minor GC.**
- Bump allocator (`ctx.nursery_buf`, `ctx.nursery_top`,
  `ctx.nursery_end`).
- `nursery_alloc(ctx, size)` fast path returning a fresh cell.
- Promotion-on-survival: minor GC copies live cells out of the
  nursery into the old-gen array.
- Minor GC walks roots + nursery only; no remembered set yet
  (correctness pass before perf).

**Session 3 — write barrier + remembered set.**
- Barrier op emitted at every old → young store.
- Open-addressing hash table for the remembered set.
- Promote on Nth minor (start with always-promote, switch to N=2 if
  profiling says).

**Session 4 — measurement + tuning.**
- Re-run the bench set, record before/after pauses in the existing
  GC-instrumentation counters.
- Bench against `qjs` to see if we hold our cross-engine lead.
- Tune nursery size, promotion age, threshold cap.
- Update `docs/perf/index.html` headline.

## Open questions

- **Nursery size?** 1 MB is the V8 default; for our cell sizes
  (60-200 bytes) that's 5-15 K cells. Worth a sweep once everything
  works — too small means frequent minors, too large means pauses
  return.
- **Stop-and-copy vs mark-and-promote?** Copy is the standard
  nursery design (Cheney's algorithm). Mark-only with promotion-by-
  age is simpler but doesn't compact the nursery. We probably want
  copy; the copy cost is small relative to the won pause time.
- **String interning interaction.** Interned strings (atoms) are
  pinned via `ctx.atom_table` — they need to never enter the
  nursery, or atom lookups break. Allocate atoms straight to old-gen.
- **What about strings produced by user code?** Those should hit the
  nursery and survive to old-gen on intern, dedup on a second
  reference.

## Verdict (2026-05-18)

Sessions 2 and 3 both shipped scaffolding (young/old split, rem-set
fields, write-barrier helper, minor-mode mark walker) but the **minor
trigger is OFF in tree**. Engine ships with single-generation
mark-sweep semantics — same as before the experiment.

What the data showed:

| Mode | object_alloc max pause | splay max pause | splay total GC |
|------|-----------------------:|----------------:|---------------:|
| Baseline mark-sweep    | 0.09 ms | 18.7 ms | 28.9 ms |
| Session 2 minor-on     | 0.06 ms | 18.5 ms | 57.5 ms (regression) |
| Session 3 with partial barriers | small win | **hangs** | n/a |

Session 3's win on splay (the only workload that would benefit) is
gated on a **complete** audit of every heap-pointer write site. We
covered `object_set` / `array_set` / `map_set_entry` / `set_add_entry`
/ `promise_settle` / `obj.cls`. Still uncovered: `o.proto = ...`,
`hf.bound = ...`, `hf.prototype = ...`, `pr.reactions[...] = ...`,
`ac.saved_*`, `g.saved_*`, `cl.env = ...`, accessor `.get`/`.set`,
template-cache writes, and the chain of bootstrap-time assignments.
Each missed site is a latent use-after-free when an old cell holds a
young pointer through that field.

The reasons to back off rather than push through:

1. **Real-world ROI is bounded.** 17 of 21 benches don't trigger GC
   at all; mark-sweep is invisible to them. Only splay-shape
   workloads (large persistent live set + ongoing allocation) see a
   pause-time win. We don't have a real splay-shape workload today —
   `zapp` workers are tight integer loops + short-lived JS; iOS UI
   threads don't run zjs JS.
2. **Audit complexity is real.** Roughly 25-30 careful edits across
   the codebase, each one a possible regression. Maintainability
   tax: every future heap-pointer field needs a barrier from day one.
3. **Mark-sweep is correct and fast enough for current workloads.**
   The benches that matter (richards, fib_recursive, int_loop) don't
   touch the collector. Adding complexity for invisible benefit is
   the wrong trade.

What's in tree after the experiment:

- `young_cells` / `old cells` (was just "cells") split — every new
  cell registers young; major GC promotes survivors. No observable
  behavior change since `gc_run_major` walks both lists.
- `gc_run_minor` function — works mechanically but no caller routes
  to it (`ctx_maybe_gc` only fires majors).
- Remembered-set scaffolding (`rem_set`, `gc_write_barrier`,
  `gc_barrier`) — barriers fire on the audited paths but the rem-set
  list never gets consumed.
- Per-cell `age` byte in `CellHeader` — set to OLD on promotion,
  used by the minor-mode mark walker.
- `gc_run --gc-stats` instrumentation (minor/major counters) —
  always-on counters, useful as a baseline tool whether or not we
  resume.
- `g_active_ctx` + `gc_set_active_ctx` plumbing in `interpret()` so
  the param-less `gc_barrier` finds its rem-set.

When to resume:

A real workload showing pause-sensitivity is the trigger. If a `zjs`
user's hot path hits >5 ms collection pauses on heap-heavy code, the
audit is worth finishing. The infrastructure here means the resumed
work is "complete the audit + flip `ctx_maybe_gc`" rather than
"design + scaffold + audit + flip" — about half the effort of
starting fresh.

Otherwise: revisit if a runtime-layer workload (txiki-style fetch +
WebSocket + Timers stack on top of zjs) shows up as the next major
arc.

## Session 4 — barrier audit pass (2026-05-27)

Added barriers covering the original §Verdict checklist:

- `o.proto = ...` in `Op::SetProto` + `host_object_set_prototype_of`
- `hf.prototype = ...` lazy alloc in all 9 NewInvoke / SuperCall sites
- `p.reactions[i] = ...` in `promise_attach_reaction`
- `f.template_cache[site] = cooked` after lazy build
- Generator + async-cont snapshot writes via new `gc_remember_holder`
  helper (one rem-set entry covers the whole saved_regs[] / saved_*
  bundle)
- `object_define_property_slot` — the missing path that doc'd
  enumeration *didn't* catch: this is how every class method gets
  installed on the proto, so without barriers here a young method
  installed on a recently-promoted proto leaks through every minor

What still doesn't work: with `ZJS_GC_GEN_ON` (the new opt-in flag),
test262 regresses 87.0% → 86.7% (~46 tests). The buckets:

- `class/elements/after-same-line-*` (12 tests): "should be an own
  property" — instance field or method lost during minor between
  class def and `new C()`. Repros at the engine level with `var C =
  class { m(){} }; forceGC(); new C();` — `C.prototype.m` is
  undefined post-GC. The barrier in `object_define_property_slot`
  *should* cover this, so there's a path where the method isn't
  installed through that helper, or the rem-set re-scan misses an
  intermediate cell.
- async-no-completion (9 tests): a Promise reaction stops firing
  somewhere along the chain. Suspect: an `ac.function` (the
  ZjsAsyncCont's pointer to the source Function*) — that field is
  walked at line 1336 but uses the assumption "function is owned by
  the context's function registry, no separate mark needed", which
  is a single-gen assumption that breaks here.
- "other" with empty `[strict]` / `[sloppy]` reason (~23 tests):
  silent crash. Includes async-gen-meth-dflt-* and dstr-rest-getter
  paths — all class-related.

Trigger gated behind `-DZJS_GC_GEN_ON` build flag (in
`ctx_maybe_gc`). Default builds ship with single-gen mark-sweep
unchanged (87.0% conformance). All infrastructure in tree.

To resume from here:
1. Build with `-DZJS_GC_GEN_ON` and reproduce the
   `C.prototype.m === undefined` post-GC issue at the smallest scale.
2. Add tracing to `object_define_property_slot` and the class-build
   compiler emit path to confirm whether method install actually
   routes through that helper, or through `object_set` /
   `obj.slots[]` direct writes elsewhere.
3. Once class-methods are stable, repro the async-no-completion case
   and verify ZjsAsyncCont's function field traversal.

The trade remains right per §Verdict — until a real workload
demands it, single-gen is fine. But the next push is one bisect
session away, not one architecture project.
