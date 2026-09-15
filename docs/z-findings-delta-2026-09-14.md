# z-findings — what changed after the Phase 0 spike

Companion note for handing the updated
[`z-findings.md`](z-findings.md) to an implementer who already has the
previous version.

**The G1, G2, and G3 sections are unchanged.** Work already in flight on
hex/binary literals is unaffected — re-sending the full file is safe and will
not disrupt it.

Everything below is new, and comes from actually building a NaN-boxed bytecode
interpreter in Z (`z/spike/`, results in
[`z/spike/RESULTS.md`](../z/spike/RESULTS.md)).

## New Wave 1 items — found by writing real Z, not by reading docs

| # | Finding | Note |
|---|---|---|
| **G11** | **Checked numeric conversion cannot reinterpret a bit pattern.** `u32(-42)` traps. | **Highest value of the new items.** NaN boxing needs C's `(uint32_t)i`; the spike folds the sign by hand. Every engine hits this on its first function. Natural home is `std/bits`, so **pair it with G2**. |
| G12 | No monotonic clock — `std/time` has only `sleep`/`delay`. | Any benchmark or profiler in Z must drop to `raw c` for `clock_gettime`. |
| G13 | Integer literals not contextually typed in ternary branches or comparisons against a wider operand. | Two occurrences within ten minutes of writing bit-manipulation code. |
| G14 | `while (true)` whose only exits are `return` is not recognized as diverging. | This is the shape of every bytecode interpreter loop. |
| G15 | A runtime trap prints nothing — `z run` exits 1 silently. | Diagnosing G11 meant reading emitted C to find which `abort()` fired. Compiler-generated aborts know their own source position. |

## Promoted into Wave 1

**G5 (narrow half) — integer subjects in `match`, lowering to a dense switch.**
Previously parked in Wave 2 pending evidence. The spike measured a **~25% cost**
going from a 10-opcode to a 70-opcode `if`-chain, and a real engine has ~200
opcodes. This is now the cheap, evidence-backed intervention.

## Verdicts that close or downgrade Wave 2 items

Nothing to implement here — these exist so no one spends effort on them.

| # | Was | Now |
|---|---|---|
| G4 computed goto | open question | **Not urgent.** Clang promotes a dense `if`-chain to a jump table on its own (verified in the assembly). |
| G6 bounds checks | "measure first" | **Not urgent.** The variant paying a bounds check per cell access still ran at 0.88× the C baseline. |
| G9 raw pointers | large open ask | **Largely dissolves.** The rewrite is adopting handle-based cells, so no raw pointer touches the object graph. |

## Suggested order from here

1. **G1** — in flight.
2. **G2 + G11 together** — same module, and G11 is what NaN boxing actually
   needs.
3. **G5-narrow** — integer `match`.
4. **G3** — `std/math` breadth (largest, but purely mechanical).
5. **G12–G15** — small DX/correctness fixes, independent of each other.

## One result worth knowing

An `if`-chain interpreter written in **ordinary Z ran at 0.84× the C
computed-goto baseline** — faster than C, and faster than the same loop written
as whole-function `raw c` (0.99×). Z's generated code is not the bottleneck
anyone expected it to be. The gaps above are ergonomics and expressiveness, not
performance.
