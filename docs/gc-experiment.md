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
