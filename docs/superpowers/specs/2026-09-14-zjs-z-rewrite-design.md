# ZJS Engine Rewrite: Zen-c → Z — Design

**Date:** 2026-09-14
**Status:** Approved direction, pre-implementation
**Supersedes:** [`2026-06-20-zjs-nim-migration-design.md`](../../../prior-art/nim/docs/superpowers/specs/2026-06-20-zjs-nim-migration-design.md)
(Nim is no longer the target: Zapp has since migrated itself to **Z**, not Nim.)

---

## 1. The engine we are building

This is the north star. Every decision below is judged against it.

| Goal | Meaning |
|---|---|
| **Embeddable** | A library first, a CLI second. Clean C ABI; host owns the loop. |
| **Small** | Size is a feature, not an afterthought. Zapp's budget is **550 KB**; the 2026-06-11 audit puts the shipped embedder at **1211 KB** full, **1060 KB** minimal tier, **974 KB** minimal + `ZJS_NO_TEMPORAL`. The gap is real and growing. |
| **Fastest jitless engine we can build** | Currently ~2.05× QuickJS-ng jitless. That is the bar to re-earn, then beat. |
| **Opt-in JIT** | Jitless is the product stance (iOS, embeddability). The JIT is a bonus tier, never a dependency. |
| **Web APIs + WinterTC compliance** | Full, not token. **Modular**, so compliance never taxes an embedder who doesn't want it. |
| **Cross-platform** | macOS first — because Z is macOS-only today — with the port path designed in, not retrofitted. |

### Why ZJS exists

The small/compact engines are slow (txiki), lack web APIs, or are niche
(Hermes). The fast, full-featured runtimes (Bun, Deno, Node) are huge. The
Zen-c and Nim prior art proved a fourth point on that map is reachable:
**modular, small, fast, embeddable, opt-in JIT, fully WinterTC-compliant with
real web APIs.**

That combination is unusually well matched to its first consumer. Zapp spawns
workers independent of its webview windows, and those workers need blazing-fast
access to the native backend — which is a Z-to-Z call if the engine is Z.

---

## 2. Why rewrite in Z

Four drivers, stated honestly, with the evidence gathered 2026-09-14.

**1. Toolchain unification with Zapp — the strongest it has ever been.**
Zapp is **169,817 LOC of Z** and already consumes `libzjs.a` through a
hand-written C/ObjC shim (`native/z/framework/worker/zjs/`). One language
across host and engine collapses that seam.

**2. Z informs the language.** This is a stated goal of the project, not a side
effect. A 65k-LOC JS engine is the most demanding consumer Z will have. Every
gap it hits is a language finding, captured in a running ledger (§7) and handed
upstream.

**3. Size and codegen quality — measured, not hoped.** From
`z-lang/benchmarks/results/checkpoint-2026-09-08-macos-arm64.md`:

| Workload | Z vs C | Nim vs C | Stripped binary |
|---|---|---|---|
| arithmetic | 1.008× | 1.035× | Z/C **33.6 KiB** |
| direct-c-call | 1.007× | 1.006× | Rust 363 KiB |
| dynamic-array | 1.028× | 4.281× | Zig 377 KiB |
| struct-ownership | 0.995× | 1.993× | Nim 66.8 KiB |

Z lands within ~1% of C on generated-code quality and matches C on binary size.
It beats Nim on both drivers that motivated the Nim plan.

**4. Off Zen-c.** The original driver was bus factor — a single-maintainer
niche transpiler. Z is also single-maintainer, but it is **ours**: the gap
between "blocked by the compiler" and "fix the compiler" is the whole point.

### Scale is already proven

Z's own self-hosted frontend is **~115k LOC across 59 modules**, including a
34.5k-line `lowering-ir.zs`, reaching a byte-identical fixed point. A 65k-LOC
engine sits inside an envelope the language has already survived. Checking that
graph takes **2.3 s** with the native `z` (6.9 s through Stage-0/Bun) — fast
enough for a test262 iteration loop.

---

## 3. This is a rewrite, not a port

The most important instruction shaping this document:

> *"We took a lot of time to do experiments but I want us to be open to any and
> all refactors to meet our goals. Everything is on the table for 'is this the
> best way to do this in Z aligned with our goals'."*

So the Zen-c engine is a **reference implementation and a behavioral oracle,
not a blueprint.** Its hard-won decisions (NaN boxing, hidden classes, inline
caches, generational nursery, atom interning) are evidence about what works,
weighed on their merits — not inherited.

**The one hard invariant is behavior:** same observable JS, same test262
pass/fail, same thrown errors. Everything internal — value layout, bytecode,
GC, object model, module decomposition, the C ABI's shape — is open, and should
change wherever Z plus the §1 goals point somewhere better.

Consequence for testing: structural diffs (AST dump, disasm diff) are a
convenience only where representations happen to align. The real oracle is
**behavioral** — run the program through both engines, compare output.

---

## 4. Z readiness: what works, what's missing

Every row below was verified by writing and running Z on 2026-09-14, not read
off a table.

### Works today

| Capability | Evidence |
|---|---|
| `u64` bitwise `& \| ^ ~ << >>` | probe ran |
| f64↔u64 bit-reinterpret | 4-line `raw c` + `memcpy`, same trick Zen-c uses at `src/value.zc:63` |
| `malloc`'d cells, pointer-as-`usize`, indexed load/store | probe ran; lowers to plain `static` C that clang inlines |
| `inout Context` threaded through helpers | probe ran; no loan-checker friction |
| Copy a value struct out of `Array<T>`, then mutate the owner | probe ran |
| Wrapping/saturating integer ops | `wrappingAdd`, `saturatingMul`, … |
| Publishing a C ABI | `export c function`, `c struct`, `c enum` + generated header |

`ZjsValue` is `typedef struct { uint64_t bits; }` — directly expressible as a
Z `c struct`.

### Gap ledger — the upstream Z roadmap this project generates

| # | Gap | Impact on ZJS | Size | Priority |
|---|---|---|---|---|
| G1 | **No hex/binary literals** — lexer scans `[0-9]` with optional `.`/exponent only | Every NaN-box constant, mask, and opcode is hex today | small | **now** |
| G2 | **No bitcast intrinsic** | `raw c` per conversion; wants `std/bits` (bitcast, popcount, clz, ctz, byteswap) | small | **now** |
| G3 | **`std/math` has exactly one function (`trunc`)** | `Math.*`, number formatting, `fmod`, `pow`, `isnan`, infinities | medium | **now** |
| G4 | **No `goto`, labels, or computed goto** | The designed dispatch architecture (Hermes-style `goto *table[op]`) is inexpressible in Z | large | §6.1 |
| G5 | **`match` is enum-variants-only**; no int match, no int→enum | Bytecode dispatch has no jump-table form in safe Z | medium | §6.1 |
| G6 | **Array indexing always bounds-checks** (`if (index >= length) abort()`), no unchecked form | Per-access cost in the hottest loops | medium | measure first |
| G7 | **`export c function` rejects pointer parameters** | `zjs.h` is `ZjsContext*` throughout | medium | shim for now |
| G8 | **No thread-local module state** (`Once<T>` is one app-lifetime root) | Engine uses `_Thread_local` globals; Zapp's multi-worker model depends on it | medium | §6.3 |
| G9 | **No raw pointer types** — unsafe pointers are scope-local, non-storable, non-dereferenceable | Zen-c writes `ZjsValue*` / `f.code_len` directly; Z cannot | large | §6.2 |
| G10 | **Cross-platform** — Z is macOS-only | Blocks the cross-platform goal at the language level | large | track |

G1–G3 are cheap and unblock real work; land them early. G4–G6 and G9 are the
substantive language conversations, and §6 is where the spike decides how much
of each we actually need.

### The Zen-c baseline, for honesty

The current engine contains **2,117 `raw {}` blocks** — 1,421 in `context.zc`
alone. Zen-c's escape hatch is used constantly. Z's `raw c` is *more*
disciplined (explicit `using (in/inout/out)` operands, lowered to an isolated
helper so native `return` cannot bypass Z cleanup) — which means each site is
safer and more verbose. We are not escaping C by moving to Z; we are choosing
where the boundary sits, deliberately.

---

## 5. Invariants

- **Behavioral parity is the contract.** test262 ≥ 24,593 (89.2% of 27,568;
  90.3% excluding skips), 0 net regressions, measured exactly as today.
- **The Zen-c engine is never degraded.** It keeps shipping to Zapp and serves
  as the differential oracle throughout.
- **Branch topology:** `main` stays pure shippable Zen-c in `src/`. A
  long-lived **`z` integration branch** holds the rewrite in a **`z/`
  subdirectory beside `src/`**; each phase is a sub-branch off `z`, merged back
  `--no-ff`, one merge per completed phase. When all gates are green, `z`
  merges to `main` — that is the cutover. Both trees coexisting on the branch
  is what keeps the differential oracle cheap.
- **The embedding contract is the seam.** `zjs.h` stays behaviorally frozen for
  the first cutover so the test262 harness, `embed_smoke.c`, and Zapp bind
  unchanged. Until G7 lands, a thin generated C shim bridges `ZjsContext*` to
  Z's `uintptr_t` exports — the same pattern Zapp already uses.

---

## 6. The three core-architecture questions

These are open, they are the interesting part, and the spike (Phase 0) exists
to answer the first two with measurements rather than argument.

### 6.1 Dispatch — how does an interpreter loop work in Z?

The design study chose Hermes-style computed goto (`goto *opcodeTable[op]`),
with a `switch` fallback. **Z has neither**, and `match` is enum-only (G4, G5).

Mitigating fact: the current engine **has not landed computed goto** and still
reaches 2.05× QuickJS-ng jitless — `src/interpreter.zc:4` records that the real
lever was value representation, not the dispatch primitive. So this caps the
ceiling; it does not block the project.

Three candidates:

- **(a) Whole-function `raw c`.** Honest and available today, but the single
  hottest and largest component stays C. Weak on driver #2.
- **(b) Z grows dispatch.** A checked `dispatch (opcode) { ... }` construct
  lowering to computed goto with a switch fallback. Most direct, largest
  language change.
- **(c) Tail-called per-handler functions.** Each opcode becomes an ordinary Z
  function ending in a guaranteed tail call. The design study *rejected* this
  for Zen-c specifically because "Zen-c might add cleanup shims for moved values
  that break it" — but **Z statically knows what cleanup is pending.** Z can
  *verify* a tail call is cleanup-free where Zen-c could only hope. This turns
  the interpreter into ordinary Z functions instead of one mega-function, and
  the language feature needed (a checked tail-call effect) is far smaller than
  computed goto.

**(c) is the most interesting answer and the most Z-shaped one.** The spike
measures (a) and (c) against the Zen-c baseline before we commit.

### 6.2 The JS heap — pointers, or handles?

Zen-c writes real typed pointers (`ZjsValue*`, `regs[i]`, `f.code_len`). Z has
no equivalent (G9). Two ways out:

- **(a) Pointer-as-`usize` + `raw c` accessors.** Mirrors Zen-c. Verified
  working. Every field access becomes a raw-c helper call — inlined by clang,
  but ~2,000 such sites and no Z-level type safety on the object graph.
- **(b) Handle/pool cells.** Cells live in Z-owned `Array<T>` pools per tag; a
  "pointer" in the NaN box becomes a **32-bit handle**, not an address. This is
  worth taking seriously:
  - No raw pointers anywhere in the object graph — the GC operates over Z
    values with Z's ownership intact.
  - Handles are smaller than 48-bit pointers, so NaN boxing gets *easier*.
  - Handles are position-independent, which makes the **AOT bytecode bundle and
    mmap'd zero-copy load nearly free** — a stated goal today solved by
    accident.
  - Trivially cross-platform.
  - Costs: an extra base-load indirection per access (register-resident in hot
    loops), a bounds check per access (G6), and a pool-compaction GC rather than
    a mark-sweep over malloc'd cells.

This decision determines the shape of the entire engine. **The spike builds
both and measures.**

### 6.3 Context, realms, and threads

The engine uses `_Thread_local` globals (G8) and Zapp's multi-worker model
depends on one context per thread. Z has no thread-local module state, and
`inout Context` threading verified clean in probes.

Threading the context explicitly is more Z-idiomatic *and* removes the global —
but it collides with `docs/realm-refactor-design.md`, which already argues for
splitting `ZjsContext` into `ZjsRuntime` (shared heap, one per agent) and
`ZjsRealm` (per-realm globals/intrinsics). **The rewrite should adopt that split
from day one** rather than port the monolith and refactor later. Deferred to the
phase that builds the context; not a spike question.

---

## 7. Modularity is architecture, not configuration

`docs/stdlib-design.md` already defines three rings — Ring 0 always linked,
Ring 1 registration-based opt-out, Ring 2 `#ifdef` build flags. It works, but
the size audit records its limit plainly: **`libzjs.a` is 2314 KB regardless of
tier**, because the archive holds every tier's symbols and the *linker*
dead-strips at the consumer link. Tiering shrinks the final binary; it never
shrinks what we ship.

Z changes what's possible here. Real modules and `z.json` package manifests mean
**unselected modules are never compiled or linked at all** — the archive itself
shrinks, not just the final binary. Feature selection becomes a manifest
decision rather than an `#ifdef` matrix.

This directly serves the 550 KB Zapp budget, and it is the single clearest
example of "is this the best way to do this in Z" producing a better answer than
the port would have.

**Decomposition is also a hard requirement.** `context.zc` is 34,528 lines. The
Z engine is a module graph from the first commit — one module per builtin family
and per stdlib module. No file inherits that size.

The JS-implemented stdlib (`node_path.js`, `web_streams.js`, and their `.gen.h`
bundles) rides along unchanged. Keeping web APIs *above* the engine seam also
keeps §10 cheap.

---

## 8. Phase plan

| Phase | Build | Gate |
|---|---|---|
| **0 — Spike ⭐** | Throwaway Z: NaN-boxed value, both heap models (§6.2), both dispatch models (§6.1), a tiny bytecode loop. Zen-c/C equivalent for comparison. | **Days, not weeks. Measures size, microbench, and `raw c` ergonomics before any real porting. Decides §6.1 and §6.2.** |
| **1 — Scaffold + loop** | Z project in `z/`, C-ABI skeleton + shim, `libzjs.a`, `test262_runner.c` linking and printing 0/27568, differential harness | the loop works end to end |
| **2 — Value + allocator** | Value representation per the spike verdict; cell header; allocator | unit round-trips |
| **3 — Lexer/parser/AST** | idiomatic Z register | unit + behavioral diff |
| **4 — Bytecode + compiler** | op set, AST→bytecode | disasm diff where aligned |
| **5 — Interpreter core** | dispatch per the spike verdict, arithmetic, control flow, calls, frames | **first real test262 number** |
| **CHECKPOINT** | re-measure size + perf against the equivalent Zen-c subset | second go/no-go, before breadth |
| **6 — GC** | per §6.2 verdict; write barriers | test262 green under aggressive GC |
| **7 — Builtins + stdlib breadth** | the ~34k-LOC surface, as a module graph (§7) | per-family test262 clusters; parallelizable |
| **8 — Perf to the gate** | ICs, per-shape property tables, fusion, PGO | bench band |
| **9 — JIT + AOT** | copy-and-patch JIT, AOT bundle | **deferrable past first cutover** |
| **10 — Cutover** | Zapp swaps `libzjs.a` via C ABI, then `import zjs` natively | the two parity gates |

The **differential oracle** runs from Phase 3 onward: every input through both
engines, outputs diffed. Any divergence is localized, never a needle in 65k LOC.

---

## 9. Cutover gates

All measured exactly as today, all green before Zapp cuts over:

1. **Conformance** — test262 ≥ 24,593, 0 net regressions.
2. **Perf** — bench geomean ≥ 0.95× current PGO.
3. **Size** — embedder binary ≤ current at the equivalent config (1211 KB
   full / 974 KB minimal+no-Temporal); **target: close meaningful ground toward
   the 550 KB Zapp budget** using §7's linking model.
4. **Embed smoke** — the 399-assert `embed_smoke.c` green.
5. **WinterTC** — 100% MCA suite.
6. **Zapp's own gate** — `verify-zjs-worker-fetch.sh` green.

---

## 10. Parked: the engine-agnostic contract

Bare-JS's approach — an agnostic contract over swappable engines — is
interesting for Zapp specifically, because **JSC ships free inside macOS and
iOS** but has no web APIs. Providing our web-API and WinterTC layer over a JSC
backend would be valuable.

**Out of scope, deliberately not over-indexed on.** But it costs nothing now to
keep the web-API/stdlib layer sitting *above* a narrow engine seam rather than
reaching into engine internals — which §7 already wants for size reasons. If the
JSC idea is ever picked up, that discipline is what makes it possible.

---

## 11. Open questions

- **Bytecode format.** Internal, so ours to choose. Keeping op *semantics*
  aligned with Zen-c buys disasm-diff convenience in Phase 4 only.
- **String representation.** Latin-1/UCS-2 dual storage + atom interning is the
  current design; how atoms interact with the §6.2 verdict is open.
- **Error model.** JS exceptions are a `pending_throw` bridge + explicit
  unwinding today. Whether Z's typed `throws`/`Result` serves the hot path or
  only the idiomatic register is a Phase-5 decision.
- **Cross-platform sequencing.** macOS first. Z's own cross-platform work (G10)
  gates this; findings feed the upstream ledger.

---

## 12. Upstream findings ledger

Driver #2 needs an artifact, not good intentions.
[`docs/z-findings.md`](../../z-findings.md) is that artifact, and it is written
as a **handoff**, not a diary: each finding is a self-contained work item — what
ZJS needs, a concrete spec, the exact files in *both* z-lang compilers, known
traps, and an acceptance bar — so it can be picked up and implemented without
reading the ZJS codebase or this design.

It is maintained from Phase 0 onward and handed to z-lang as its own input,
**not** as part of this design. Items are staged: Wave 1 is cheap and mechanical
(hex literals, `std/bits`, `std/math` breadth) and can start immediately; Wave 2
carries real language design (dispatch, pointers) and waits on spike evidence;
Wave 3 is strategic and tracked.
