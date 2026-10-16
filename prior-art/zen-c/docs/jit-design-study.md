# zjs — Optional JIT Design Study

> Companion to [`jitless-design-study.md`](./jitless-design-study.md). That
> doc is the engine; this one is the *additive, opt-in* accelerator for the
> platforms that allow runtime codegen. Written as JIT work comes into view
> (~86.6% test262, interpreter mature) — a decision-capture, not a commitment.

## Mission recap

The founding thesis is **jitless-first, not jitless-only**. The interpreter
is the product; the JIT is a *second-class*, opt-in tier that exists only to
push **beyond** our jitless peer (QuickJS) toward JSC/V8-class desktop
throughput. Constraints, in priority order:

1. **iOS / sandboxed / App Store builds stay pure interpreter.** `mmap(PROT_EXEC)`
   is forbidden there; the JIT must be a *compile-time* opt-in that those
   targets simply don't include. This is non-negotiable — it's the reason the
   engine exists.
2. **Known consumer: zapp on desktop** (macOS/Linux/Windows), where runtime
   codegen is allowed. No other consumer is assumed.
3. **Additive, never a substitute.** Every JIT'd function must be able to fall
   back to the interpreter at any safepoint. The interpreter remains the
   source of truth for semantics.
4. **Minimal dependency / minimal binary growth.** A ~1.3 MB engine doesn't
   get to embed LLVM. The JIT must stay small and only cost binary size when
   compiled in.

Grading question for every decision below: **does this beat the interpreter
by enough to justify the complexity, the W^X attack surface, and the binary
growth — without compromising the iOS interpreter-only build?**

## Preconditions — the threshold gate

Do **not** start JIT *implementation* until all three legs hold (validate,
don't assume — see [feedback: perf-speculation]):

| Leg | Target | Status (2026-06-04) |
|---|---|---|
| Conformance | ~90%+ test262, core semantics solid | **86.6% curated** — close, not arrived |
| Jitless perf | at/around QuickJS on the bench suite | re-measure vs current qjs before greenlight |
| Runtime surface | zapp's runtime needs met | check with zapp |

The **design study (this doc) can proceed now**; the **substrate spike**
(Phase 1 below) can proceed now as a research GO/NO-GO; full implementation
waits on the gate.

## Decisions at a glance

| # | Topic | Recommendation | Why (short) |
|---|---|---|---|
| 1 | Substrate | **Copy-and-patch** stencils, baseline only | No runtime dep, tiny, portable, same clang ⇒ same semantics |
| 2 | Shape | **Method JIT** (whole hot function), not tracing | Simpler deopt; matches the register bytecode |
| 3 | Tiering | Interpreter (T0) → baseline JIT (T1). No optimizing tier in v1 | Ship the 80% win first |
| 4 | Frame model | Keep values in the **interpreter frame layout** (no regalloc) | Makes deopt + GC scan *free* |
| 5 | ICs | **Reuse the existing shape-keyed IC side-table**, emit guards inline | Already realm-safe; no new metadata |
| 6 | Guards | Identity/shape guard **+ deopt**, never "the unique intrinsic" | Keeps realms a perf retrofit, not a correctness one |
| 7 | Deopt | Guard-fail → re-enter interpreter at the bytecode index | Trivial because frame layout is shared |
| 8 | GC | GC scans JIT frames **the same way** as interpreter frames | No precise register stack maps in v1 |
| 9 | Platform | Compile-time `ZJS_JIT`, **off by default, forced off on iOS** | The whole point |
| 10 | W^X | Never RWX; `MAP_JIT` + jit-write-protect toggle on Apple Silicon | Security + Apple requirement |
| 11 | AOT | JIT composes with the AOT bytecode bundle (`zjsc`) | Same bytecode in; no conflict |

## 1. Substrate — copy-and-patch baseline

**Recommendation.** A **copy-and-patch** JIT: at build time, clang compiles one
small relocatable *stencil* per (opcode, operand-width) into a table with
"holes" (immediates, branch targets, runtime-helper addresses). At runtime the
JIT stitches a function's bytecode into machine code by *copying* the stencils
and *patching* the holes. No assembler, no LLVM, no IR at runtime.

**Why.**
- **Zero runtime codegen dependency** and tiny footprint — fits the embeddable
  thesis far better than LLVM ORC (huge) or Cranelift (a Rust dependency that
  breaks the single-Zen-c-toolchain story).
- **Semantics match by construction**: the stencils are compiled by the *same*
  clang `-O3` that builds the interpreter, from the *same* op-body C, so a JIT'd
  `Add` does exactly what the interpreted `Add` does. This is a conformance
  superpower — the JIT can't drift from the interpreter.
- Compile time is essentially memcpy + relocation — cheap enough to JIT on the
  first hot call without a background thread.

**Reconsider if.** A profiled optimizing tier later wants cross-op optimization
or real register allocation — then a **hand-rolled baseline assembler** (JSC /
LuaJIT style) becomes the substrate for *that* tier. Keep copy-and-patch as T1
regardless; it's the cheap, portable baseline.

**Rejected alternatives.** libtcc (poor codegen, runtime dep, size); LLVM ORC
(binary size, compile latency); Cranelift (Rust dep); hand-rolled asm as the
*first* substrate (per-arch maintenance burden too high for a baseline).

**Refs.** Xu & Kjølstad, *Copy-and-Patch Compilation* (OOPSLA 2021); the
CPython 3.13+ experimental JIT build tooling (its `jit.py`/stencil generator is
the closest production example of extracting copy-and-patch stencils from a
C compiler and is worth reading before the Phase-1 spike).

## 2–4. Shape, tiering, frame model — and why baseline is the *easy* path

**Method JIT, not tracing.** Compile a whole hot function to machine code on
tier-up. Tracing buys more on tight loops but its deopt/guard story is far
hairier; a method JIT over our existing register bytecode is the lower-risk
match.

**Hotness.** Per-function call counter + loop back-edge counter; cross a
threshold ⇒ compile the function. **OSR (on-stack replacement)** for a function
already spinning in a long loop is **deferred to v2** — v1 tiers up on the next
*call*, so a single never-returning loop won't tier mid-run. Acceptable to
start.

**Frame model — the key simplification.** The baseline does **no register
allocation**: JIT'd code keeps every virtual register in the *same stack-frame
slot the interpreter uses*. The win is **not** regalloc — it's deleting the
dispatch indirect-branch per op, baking immediates as constants, and
straight-lining the hot path for the i-cache and branch predictor. Because the
frame layout is identical to the interpreter's:

- **Deopt is free** (§7): re-entering the interpreter needs no register→frame
  reconstruction — the frame already *is* the interpreter's register file.
- **GC is free** (§8): the collector scans a JIT frame with the exact same
  frame-walk it uses for interpreter frames.

This is the central argument for copy-and-patch baseline over a "real" JIT: it
trades peak code quality for *trivial* deopt + GC integration, which are the
two things that sink most hobby JITs.

**Honest caveat (perf-speculation discipline).** Our dispatch is *already* a
single jump-tabled indirect branch (clang `-O3` folds the op chain — see
[dispatch already jump-tabled]). So the baseline JIT is beating an already-good
interpreter; its win is the per-op dispatch branch + operand decode + inlined IC
checks, concentrated on hot arithmetic/property loops. **Prove it on one loop
before building the pipeline** — that's the Phase-1 GO/NO-GO.

## 5–6. Inline caches and the realm-aware guard principle

**Reuse the existing IC side-table.** The interpreter's ICs already key on
**hidden class (shape)**, not on realm or global identity
(`ic->classes[i] == cls`). The JIT emits the same monomorphic/polymorphic guard
inline: load the receiver's shape, compare against the cached class(es), hit ⇒
inline slot access, miss ⇒ call the shared IC-miss helper that updates the
side-table. No new metadata; the IC layer is **realm-ready by construction**.

**The one principle that protects the realm option (§ see realm note below).**

> **Every intrinsic/global speculation is an identity-or-shape guard with a
> deopt path — never a "there is exactly one Array.prototype" assumption.**

This is nearly free because it's already how the ICs work. It's the difference
between realms-after-JIT being a *performance retrofit* (cross-realm objects
fail the guard and take the slow path — correct, just slow) versus a
*correctness re-audit*. The ~423 `ctx.*_proto` intrinsic fast-path checks in
the interpreter are the **known surface** that would later need realm-keying;
they are all guards-with-fallbacks today, so they stay correct.

## 7. Deopt

A guard the JIT can't resolve inline (type change, megamorphic blowup, debugger
attach, an unrecognized cross-realm intrinsic) **bails to the interpreter** at
the bytecode index for that safepoint. Metadata per safepoint: `jit_pc →
bytecode_index`. Frame reconstruction is a no-op (§4). Keep safepoints at
back-edges, calls, and allocation sites.

## 8. GC integration

The collector already walks interpreter frames to find live `ZjsValue`s
(register area + the cold call-frame fields). A JIT'd frame has the **same
layout**, so the same walk applies — **no precise per-instruction register
stack maps in v1**. (An optimizing tier with real regalloc *would* need precise
maps; that's a v2 cost, explicitly deferred.) This must stay consistent with
the generational mark-sweep and the deferred GC-in-allocator work — JIT'd
allocation sites must hit the same write-barrier and safepoint hooks.

## 9–10. Platform gate, W^X, entitlements

- **`ZJS_JIT` compile-time flag, off by default.** iOS/tvOS/sandboxed builds
  **never** set it. macOS/Linux/Windows desktop (zapp) opt in.
- **W^X always; never map RWX.** Linux/Windows/Intel macOS: `mmap` RW → write →
  `mprotect`/`VirtualProtect` RX. **Apple Silicon**: `MAP_JIT` pages +
  `pthread_jit_write_protect_np()` to toggle per-thread write protection, plus
  the `com.apple.security.cs.allow-jit` entitlement under the hardened runtime.
- Maintain a **JIT platform-support matrix** in
  [`platform-port-status.md`](./platform-port-status.md) per the platform-port
  discipline.

## What this JIT intentionally is NOT

- **Not for iOS.** Ever. Interpreter-only there is the founding promise.
- **Not a tracing JIT**, not an optimizing/speculative tier in v1.
- **Not on by default**, not a replacement for the interpreter.
- **Not realm-complete** — it just doesn't *preclude* realms (§6).

## Implementation order

0. **(this doc)** design study + the realm-guard principle.
1. **Substrate spike — GO/NO-GO.** Build-time stencil generator (clang →
   relocatable stencils) for a handful of ops; JIT one hot arithmetic/property
   loop end-to-end; **measure vs the interpreter on the bench suite.** If the
   win doesn't clear a meaningful bar, stop — the interpreter is already good.
2. Full opcode-coverage stencils; method-JIT of hot functions; tier-up policy.
3. ICs inlined in JIT'd code (reuse the side-table).
4. Deopt (guard-fail → interpreter at bytecode index).
5. GC frame-scan integration (reuse the interpreter frame walk) + barrier/safepoint parity.
6. Platform gate + W^X + entitlements; zapp-desktop enablement; platform matrix.
7. **(later, only if profiles justify)** optimizing tier / OSR / real regalloc
   — which is where precise stack maps + a hand-rolled assembler would enter.

## Open questions (for the relevant phase)

- **Stencil extraction mechanism** — the trickiest engineering bit: how to get
  clean relocatable stencils + hole descriptors out of clang at build time
  (CPython's tooling is the reference). Per-arch (x86-64, arm64) stencil tables.
- Tier-up thresholds (call count / loop count) — tune empirically.
- OSR in v1 vs v2 (currently v2).
- Binary-size budget when `ZJS_JIT` is on (stencils per arch) vs the size goal —
  acceptable because it's compile-gated, but quantify.
- Constant-blinding / immediate-spraying mitigations — low priority for a
  non-browser embed, but note before exposing JIT to untrusted input.
- Interaction with the AOT bundle: JIT hot functions loaded from `.zbc` — verify
  the bytecode-index ↔ source mapping survives AOT for deopt/debugging.

## Realm note (cross-cutting) — UPDATED

> An earlier draft here called cross-realm "deferred / prohibitive." **That was
> too conservative and is corrected** in [`realm-refactor-design.md`](./realm-refactor-design.md):
> realms are *shared-heap + per-realm-globals* (QuickJS's `JSRuntime`/`JSContext`),
> NOT separate heaps — so they don't break the GC, and the refactor is the
> well-trodden split a peer engine already shipped. The plan is to land it
> **before** JIT implementation.

This makes the §6 guard principle **load-bearing**, not hypothetical: every
intrinsic/global speculation in the JIT MUST be an identity/shape guard with a
deopt path, never "the unique `Array.prototype`," because once realms exist there
genuinely are several. With realms landing first, the JIT is realm-correct by
construction (a cross-realm object fails the guard → slow path) and a future
optimizing tier can realm-key its speculation deliberately. The ~423
`ctx.<intrinsic>` sites the realm refactor makes realm-scoped are the same
surface the JIT speculates against — do the realm split first and the JIT
inherits the right shape.

## Refs — prior art bookmarks

- **Copy-and-patch**: Xu & Kjølstad (OOPSLA 2021); CPython 3.13+ JIT (`Tools/jit/`).
- **Baseline JITs**: JSC's Baseline + the LLInt→Baseline handoff; V8 Sparkplug
  (single-pass, no IR — close in spirit to copy-and-patch); LuaJIT interpreter+JIT.
- **Deopt / OSR**: V8 Crankshaft/Maglev deopt notes; JSC OSR exit.
- **W^X / Apple Silicon**: `MAP_JIT`, `pthread_jit_write_protect_np`,
  hardened-runtime `allow-jit` entitlement.
- In-repo: [`jitless-design-study.md`](./jitless-design-study.md) (the
  interpreter decisions this builds on), [`aot-bytecode-format.md`](./aot-bytecode-format.md),
  [`gc-experiment.md`](./gc-experiment.md), [`platform-port-status.md`](./platform-port-status.md).
