# ZJS Engine Migration: Zen-c → Nim — Design

**Date:** 2026-06-20
**Status:** Approved design, pre-implementation
**Author:** Zach + Claude (brainstorming session)

---

## 1. Context & decision

ZJS is a ~68.7k-LOC JavaScript engine currently written in **Zen-c** (a niche,
single-maintainer language that transpiles to C). It is at 90.3% test262
(24,593 passing) and ~2.05× faster than QuickJS-ng jitless, with a hard-won
perf stack (NaN-boxing, generational nursery GC, jump-tabled dispatch,
InvokeGlobal/Mov fusion, PGO) and an opt-in copy-and-patch JIT.

Zapp (the first embedder, desktop/iOS framework) has already migrated **itself**
from Zen-c to Nim with strong results, including smaller builds. Nim is now a
known — though not the only — target for ZJS.

**The decision:** rewrite the ZJS engine implementation in **pure, idiomatic
Nim**, gated by the test262 suite, cutting over to Zapp once it reaches
conformance + perf + size parity. Main (Zen-c) keeps shipping throughout.

### Drivers (all four apply)

1. **Zen-c bus factor / stability** — betting a 68k-LOC engine's future on a
   personal niche transpiler is the long-term risk.
2. **Toolchain unification with Zapp** — one language across host + engine:
   shared build, shared debugging, no Zen-c dependency in the stack.
3. **Build size / output quality** — Zapp got smaller builds on Nim; ZJS wants
   the same. **Unproven for ZJS specifically — must be measured early.**
4. **Nim ecosystem / debugging / future dev velocity.**

### The reframe that shaped the plan

The embedding ABI (`include/zjs.h`, ~150 C functions, opaque `ZjsValue` /
`ZjsContext*`) is **already a clean C ABI, and Zapp-in-Nim already consumes
`libzjs.a` through it today.** "ZJS works with Nim" is therefore already true.
This migration is *not* about interop — it is about rewriting the
*implementation* from Zen-c into Nim. The C ABI is the invariant seam: zjs-nim
exposes the same `zjs.h`, so the test262 harness and Zapp bind to it unchanged.

---

## 2. Invariants (what never moves during migration)

- **`zjs.h` is the frozen contract.** zjs-nim exports a byte-compatible C ABI
  via `{.exportc, cdecl.}`. The test262 harness (which uses only 4 functions:
  `zjs_new_context`, `zjs_eval`, `zjs_had_error`, `zjs_free_context`) and Zapp
  bind to it unchanged.
- **Branch topology — a long-lived `nim` integration branch.** `main` stays
  pure shippable Zen-c (in `src/`), keeps getting conformance/Temporal/perf
  work, keeps shipping `libzjs.a` to Zapp — and is NOT cluttered with the
  in-progress (red/incomplete-for-months) Nim engine. A long-lived **`nim`
  integration branch** off `main` holds the migration; **each phase is a
  sub-branch off `nim`** (e.g. `nim-phase2-…`) that merges back into `nim`
  (`--no-ff`, one merge per completed phase). When ALL phases reach parity,
  `nim` merges to `main` — that is the cutover.
  - **Directory layout (unchanged):** the Nim engine lives in a **`nim/`
    subdirectory** beside `src/`; it does not replace `src/`. Both trees
    coexist on the `nim` branch, which is what keeps the differential oracle
    cheap (build both, run both, diff — on the branch).
  - **Keeping current:** because `main` edits `src/` and the migration edits
    `nim/` (different directories), periodic `git merge main → nim` (to refresh
    the Zen-c oracle + shared test262/tooling) is low-conflict. This periodic
    sync is the deliberate price of keeping `main` clean.
- **Acceptance is objective:** test262 conformance ≥ current (24,593) AND perf
  within the parity band AND size ≤ current — all measured exactly as today,
  before any cutover.
- **The Zen-c engine is never degraded.** It is the shipping safety net *and*
  the differential oracle.

---

## 3. Design tenets

### 3.1 The "two registers" idiom principle

Idiomatic Nim earns its keep everywhere *except* the hot core. The boundary
test: **does this code run per-bytecode-op or per-GC-cell?**

| Register | Where | Nim tools |
|---|---|---|
| **Idiomatic** | parser/AST, compiler orchestration, builtins *logic*, the embedding/host-fn API, error paths, tooling | object variants, distinct types, templates, `seq`/`openArray`, UFCS, exceptions, `std/` |
| **Systems** | value encoding (NaN-boxing), GC, interpreter dispatch loop, inline caches, hot inner loops | `ptr`, `cast`, `{.push checks:off.}`, manual layout, `{.inline.}` |

This keeps the 2.05× while making the 34k-LOC builtins breadth pleasant to write.

### 3.2 The golden rule (perf/size beats fidelity)

**Behavioral parity is the hard invariant** — same observable JS results, same
test262 pass/fail, same thrown errors. But **internal representation** (value
layout, bytecode, GC structures, data structures) is **free to deviate from
Zen-c whenever Nim offers a perf or size win — and should**, per the
fast-jitless north star.

Consequence for testing: cheap *structural* diffs (AST-dump diff, disasm diff)
work only where representation stays aligned. Where we deviate for perf/size,
we drop to **behavioral diff** (run the program through both engines, compare
output) at that layer. In practice AST/bytecode will stay close (little
perf/size to win there); deviations cluster in value/GC/IC/dispatch, which are
behaviorally checked anyway.

### 3.3 Nim memory model

- **`--mm:arc`** — deterministic, RAII-style cleanup, no stop-the-world
  collector to fight ZJS's own GC; still allows ergonomic `seq`/`string`/`ref`.
- **Two heaps, one rule:** the **JS runtime heap** (cells, the GC-managed
  object graph) is **100% manual** — `ptr` + `alloc`/`dealloc`, marked by ZJS's
  own nursery/mark-sweep GC, exactly as today. **Compile-time & host-side data**
  (AST during parse, transient compiler structures, the host API) may use
  Nim-managed `seq`/`ref` freely. **The boundary: anything the JS GC marks is
  manual; nothing Nim-managed is ever reachable from a JS cell.**
- **`{.push checks:off.}`** in the dispatch loop and hot paths; checks on
  elsewhere during dev.
- **Build:** Nim **C backend** + clang (same compiler as today) → `libzjs.a`.
  PGO and LTO still apply at the C-compile step, so the entire perf toolchain
  carries over. (Nim 2.2.10 confirmed installed.)
- **Value:** NaN-boxed `uint64` as a `distinct` type with `{.inline.}` tag-test
  procs — zero-cost idiomatic wrapping of the bit tricks.

---

## 4. Phase plan (bootstrap order)

Hard constraint: real JS can't run until value + lexer + parser + compiler +
interpreter + a GC coexist. The order is engineered to get a runnable,
test262-measurable artifact early and bring the differential oracle online fast.

| Phase | Build | Becomes testable via | Register |
|---|---|---|---|
| **0 — Scaffold + loop** | Nim project, C-ABI skeleton (4 fns, all stub), `libzjs.a`, get `test262_runner.c` **linking & running** (prints 0/27568), differential-harness skeleton | the loop itself works end-to-end | — |
| **1 — Value + stub alloc** | NaN-boxing (`distinct uint64`, tag tests, encodings), cell header, bump allocator (alloc-only, no GC) | unit round-trip tests | systems |
| **2 — Lexer/parser/AST** | tokens, recursive-descent parser, AST object-variants | unit + diff AST/token dumps vs Zen-c | idiomatic |
| **3 — Bytecode + compiler** | op set, AST→bytecode | disasm diff vs Zen-c for same source | mixed |
| **4 — Interpreter core ⭐** | dispatch loop, arithmetic, control flow, calls/frames, return | **`1+1`, loops, recursion run — test262 `language/` subset starts passing.** First real conformance number. | systems |
| **CHECKPOINT** | **Early go/no-go: build a minimal Nim lib, measure size + microbench vs the equivalent Zen-c subset.** Validates drivers #3 (size) and the perf thesis *before* the months-long breadth slog. | — | — |
| **5 — Real GC** | replace stub with nursery + mark-sweep + write barriers | test262 stays green under aggressive GC (byte-identical discipline) | systems |
| **6 — Builtins breadth** | the 34k-LOC: Object/Array/String/…/Temporal + node:/web stdlib | each family lights its test262 cluster; diff-tested. **Parallelizable, safest, longest.** | idiomatic |
| **7 — Perf to the gate** | dispatch tuning, ICs, fusion, frame layout, **PGO** | bench suite until the perf band is hit (re-earn 2.05×) | systems |
| **8 — JIT + AOT** | copy-and-patch JIT, AOT serializer | **deferrable past first cutover** — jitless-first is the product stance | systems |
| **9 — Cutover** | (1) Zapp swaps `libzjs.a` via C ABI → parity in prod; (2) later, Zapp `import zjs` native → full unification | the two parity gates | — |

### The differential oracle (the discipline that makes this safe)

From Phase 2 onward, **every input goes through both zjs-nim and the live
Zen-c engine, and outputs are diffed.** Any divergence is a *localized* bug, not
a needle in 68k LOC. You are never debugging blind; you always have a correct
reference implementation. Behavioral diff is the hard form (Section 3.2);
structural diff (AST/disasm) is a bonus where representations align.

### Decisions inside the plan

- **Bytecode is zjs-nim's own** — it is internal. Keeping op *semantics*
  aligned with Zen-c is worth it only for the disasm-diff convenience in Phase
  3; we are not bound to byte-format compatibility.
- **JIT/AOT are explicitly out of the critical path to first cutover.** Ship
  the interpreter-only Nim engine at parity; port them after. Jitless-first is
  the product stance anyway (iOS, embeddability).

---

## 5. The early go/no-go checkpoint (most important risk control)

Right after **Phase 4** — interpreter core runs, before the months-long breadth
slog — build a minimal Nim lib and **measure size + a microbench against the
equivalent Zen-c subset.** This validates driver #3 (size) and the perf thesis
*before* sinking months in, honoring the project's own "validate the perf model
with a microbench before committing to a structural refactor" discipline.

- **If the size/perf wins are real** → green-light the breadth.
- **If they are phantom and the only true driver is bus-factor** → the cheap
  "freeze the generated C" fallback is still on the table (the zc-generated C is
  a permanent, frozen artifact that needs no Zen-c toolchain to compile), and we
  have spent weeks, not months.

---

## 6. Cutover gates (all must be green, measured as today)

Before the stage-1 Zapp cutover:

1. **Conformance** — zjs-nim test262 ≥ 24,593 on the curated suite, **0 net
   regressions** vs Zen-c (ideally a superset of passes).
2. **Perf** — bench geomean ≥ **0.95×** of current PGO (no worse than 5%
   slower; ideally faster given golden-rule deviations).
3. **Size** — embedder `libzjs.a` ≤ current (driver #3; target smaller).
4. **Embed smoke** — the 399-assert `embed_smoke.c` green against the Nim lib.
5. **WinterCG** — 100% MCA suite.
6. **Zapp's own gate** — `verify-zjs-worker-fetch.sh` (embedded multi-worker GC
   gate) green.

### Two-stage Zapp cutover

1. **C-ABI swap** — Zapp swaps `libzjs.a` via the existing C ABI. Proves parity
   in production with the conservative path (no integration changes).
2. **Native import** — Zapp switches to `import zjs` as a native Nim module,
   dropping the C ABI marshalling and `{.compile.}`. Collects the full
   toolchain-unification prize (driver #2). Happens *after* parity is proven via
   stage 1.

---

## 7. Risk controls (summary)

- Differential oracle (behavioral) continuous from Phase 2.
- test262 + bench + wintercg + embed_smoke run on `nim/` from Phase 4 on
  (mostly red early — expected; track the climbing number).
- The Zen-c engine is never touched/degraded — safety net + oracle, keeps
  shipping to Zapp.
- GC correctness: port the byte-identical-under-aggressive-GC discipline at
  Phase 5.
- Two-stage cutover: the riskiest integration (native Nim import) happens
  *after* parity is proven via the conservative C-ABI swap.
- No cutover until every gate (Section 6) is green.

---

## 8. Honest scope flag

This is a **multi-month effort** (~68k LOC, though ~34k is parallelizable,
test-driven breadth). Done perfectly, it ships **zero new user-facing value** —
same engine, same conformance, same-or-better perf/size. Its payoff is
**strategic**: off Zen-c, unified toolchain, smaller builds, Nim ecosystem. The
Phase-4 checkpoint (Section 5) is what keeps that bet honest — it forces an
early, evidence-based confirmation that the size/perf drivers are real before
the bulk of the cost is incurred.

---

## 9. Open questions to settle during implementation

These are deliberately deferred to the implementation plan, not blockers now:

- **Module decomposition.** The Zen-c `context.zc` is 34.5k LOC (too big). The
  Nim breadth should be split into focused modules (one per builtin family /
  stdlib module). The exact module graph is a Phase-6 concern.
- **Error model.** JS exceptions are currently a `pending_throw` bridge +
  explicit unwinding. Decide whether the Nim implementation keeps that explicit
  model (likely, for the C-ABI host boundary and perf) or uses Nim exceptions in
  the idiomatic register only. Behavioral parity is the constraint either way.
- **String representation.** Whether to keep the current interned/atom model
  verbatim or adopt a Nim-friendly variant (a candidate perf/size deviation
  under the golden rule).
- **Concurrency / TLS.** The current engine uses `_Thread_local` engine globals
  (one ctx per thread). Map this to Nim's `{.threadvar.}` deliberately — it is
  load-bearing for Zapp's multi-worker model.
- **Bench/size measurement parity.** Ensure `scripts/bench` and the size-audit
  harness can target the Nim lib identically to the Zen-c lib for
  apples-to-apples gates.

---

*Next step: an implementation plan (writing-plans skill) decomposing Phase 0
and Phase 1 into concrete, verifiable tasks.*
