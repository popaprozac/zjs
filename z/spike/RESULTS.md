# Phase 0 spike — results

**Date:** 2026-09-14 · **Host:** Darwin 25.4.0 arm64, Apple clang
**Workload:** 20,000,000 iterations × 8 dispatches = 160M dispatches
**Method:** every variant emitted/compiled with the same `clang -O2` the Z
`--release` path uses, 9 samples each, median reported, two independent runs.
All variants produce an identical checksum (`542894464`).

Reproduce with `./run.sh` (`SAMPLES`, `SPIKE_N`, `OUT` are overridable).

## What was measured

A register-machine bytecode interpreter over a 10-opcode ISA running a loop
that mixes int32 arithmetic with heap field reads and writes — NaN-boxed values,
a register file, and a real dispatch loop. Small enough to build several ways,
representative enough that the dispatch and heap costs dominate.

| Variant | Dispatch | Heap |
|---|---|---|
| `baseline` | C computed goto | malloc + raw pointers |
| `v-inline-ptr` | Z `if`-chain, bodies inline | malloc, `usize` + `raw c` accessors |
| `v-inline-pool` | Z `if`-chain, bodies inline | Z-owned `Array<Value>`, 32-bit handles |
| `v-inline-ptr-wide` | Z `if`-chain, hot ops behind 60 cold ones | malloc + `raw c` |
| `v-table-ptr` | `Array<(inout Frame, …) => void>` indexed by opcode | malloc + `raw c` |
| `v-rawc-ptr` | whole-function `raw c` computed goto | malloc + raw pointers |

## Results

| Variant | Relative to C baseline (two runs) | Stripped size |
|---|---|---|
| **`v-inline-ptr`** | **0.841× / 0.861×** | 33 KiB |
| `v-inline-pool` | 0.880× / 0.903× | 33 KiB |
| `v-rawc-ptr` | 0.990× / 1.004× | 33 KiB |
| `baseline` (C computed goto) | 1.000× | 33 KiB |
| `v-inline-ptr-wide` | 1.049× / 1.056× | 33 KiB |
| `v-table-ptr` | 1.242× / 1.254× | 33 KiB |

Lower is faster. Ordering was identical across both runs.

---

## Findings

### 1. Ordinary Z beats C computed goto — and beats `raw c` inside Z

The plainest variant, an `if`-chain interpreter written in ordinary Z, is
**~15% faster than the C computed-goto baseline** and faster than the
whole-function `raw c` computed-goto variant (0.99×). Dropping to C for the
dispatch loop **did not buy speed on this workload** — it cost Z's ownership,
type checking, and tooling over the hottest component for nothing.

**Design option (a) in §6.1 — "the dispatch loop stays `raw c`" — is dead.** It
is the worst trade available: all of the cost, none of the benefit.

Caveat worth stating plainly: the *mechanism* is not fully explained. Computed
goto's historical advantage is multiple indirect-branch sites aiding prediction,
and on modern arm64 predictors that edge has narrowed; a compare chain that
clang converts to a switch appears to predict at least as well here. This is one
compiler, one architecture, one workload. It should be re-checked on x86-64 and
at a realistic opcode count before being treated as settled — but it is
consistent with the reference engine's own note that dispatch was never the
lever.

### 2. ISA size does cost — ~25% from 10 to 70 opcodes

`v-inline-ptr-wide` puts the hot opcodes behind 60 cold comparisons, simulating
a realistic ISA. Clang **promotes the dense chain to a jump table** (verified in
the assembly: 1 indirect branch plus jump-table data, versus 0 indirect branches
and 37 compares for the 10-opcode version). Even so it costs **~25%** relative
to the narrow chain (0.84× → 1.05×).

Two conclusions, and they point opposite ways:

- **It does not block anything.** At 70 opcodes the Z interpreter is still
  ~1.05× the C computed-goto baseline. A real engine can be written this way.
- **It keeps G4/G5 alive as a genuine ask.** A real engine has ~200 opcodes, and
  the trend is the wrong direction. Integer `match` lowering to a dense switch
  (the narrow half of G5) is the cheap intervention, and it is worth measuring
  at ~200 opcodes before committing to anything larger.

### 3. Handle-based cells cost ~5% and buy a great deal

The handle/pool heap runs at **0.880×/0.903× versus 0.841×/0.861×** for the
pointer heap — roughly **5% slower**. For that it buys:

- no raw pointers anywhere in the object graph, so G9 largely dissolves;
- position-independent handles, which makes the mmap-ready zero-copy AOT bundle
  nearly free — work currently on the roadmap;
- trivial cross-platform behavior;
- the GC operating over Z-owned values with ownership intact.

**Recommendation: adopt handle-based cells (§6.2 option b).** Five percent on a
microbenchmark is a good price for deleting an entire category of unsafety and
getting the AOT bundle as a side effect. Re-measure at engine scale, where cache
behavior over a real object graph may not match a 4-field toy.

### 4. Function-value table dispatch works today, but is the slowest option

`Array<(inout Frame, …) => void>` indexed by opcode **compiles and runs in Z
with no language change** — worth knowing. But at **1.25×** it is the slowest
variant, because without a tail call each handler returns to the loop and pays a
halt check per dispatch. It is a viable structure for cold paths, not the hot
loop.

This is also the empirical case for §6.1 option (c): the tail-call effect is
precisely what would remove the return-and-recheck that costs this variant its
25%.

### 5. Size does not discriminate at this scale

Every variant stripped to **33 KiB**, matching the C baseline exactly. Consistent
with z-lang's own benchmark evidence. The size question is real but must be
answered at engine scale, not here.

---

## What this settles for the rewrite

| Question | Verdict |
|---|---|
| §6.1 dispatch — option (a) `raw c` loop | **Rejected.** Slower than ordinary Z and costs all Z guarantees. |
| §6.1 dispatch — what to build now | **Write the interpreter in ordinary Z.** Revisit (b)/(c) with a ~200-opcode measurement. |
| §6.2 heap — pointers vs handles | **Handles.** ~5% for a large architectural win. |
| G4 computed goto | **Not urgent.** Clang's switch recovery is adequate today. |
| G5 integer `match` | **The cheap, real ask.** Directly targets the ~25% ISA-size cost. |
| G9 raw pointers | **Largely dissolves** if handles are adopted. |
| G6 bounds checks | Not isolated here; the pool variant pays them and still lands at 0.88×. Not urgent. |

## Honest limits

- One workload, one architecture, one compiler. Int32 arithmetic plus a 4-field
  object is not a JS engine.
- No GC, no strings, no property lookup, no inline caches, no polymorphism —
  all of which dominate real engine time.
- 10 and 70 opcodes, not ~200.
- Size comparison is meaningless at 33 KiB.

The spike answers the questions it was scoped to answer and nothing more. The
Phase-5 checkpoint re-measures all of it on a real interpreter core.
