# Binary-size audit — 2026-05-27

Measured after the tier system landed (Phases 1 + 2). All numbers are for
a representative embedder shape: a tiny C consumer linked statically
against `libzjs.a`, with `-Wl,-dead_strip` + `strip -S` applied. Numbers
reflect what an embedder actually ships, not the intermediate `.a`.

**Updated 2026-05-27 (banked):** LTO-by-default + `ZJS_NO_AOT_WRITER`
have landed. Default Makefile builds get LTO automatically (`ZJS_NO_LTO=1`
opts out for fast inner-loop dev). `ZJS_TIER=minimal` now includes
`ZJS_NO_AOT_WRITER` — the writer half stubs out, `zjs_compile_to_bytecode`
returns NULL, and dead-strip removes ~8-12 KB of writer code. Reader is
unaffected (loading pre-built `.zbc` still works at every tier).

| Tier               | Before this pass | After this pass | Delta |
| ------------------ | ---------------: | --------------: | ----: |
| default (full)     | 824.6 KB         | **803.1 KB**    | -21.5 KB |
| `ZJS_TIER=ring1`   | 752.4 KB         | **715.3 KB**    | -37.1 KB |
| `ZJS_TIER=minimal` | 703.6 KB         | **665.9 KB**    | -37.7 KB |

test262 unchanged at 87.0% on default tier.

Host: `Darwin 25.5.0 arm64`, Apple clang 21.0.0, zig 0.16.0.

## Tier sizes (smoke binary, dead-strip + strip -S)

| Tier             | Compiler | -flto      | Binary size |
| ---------------- | -------- | ---------- | ----------: |
| default (full)   | clang    | —          |     824.6 KB |
| `ZJS_TIER=ring1` | clang    | —          |     752.4 KB |
| `ZJS_TIER=minimal` | clang  | —          |     703.6 KB |
| `ZJS_TIER=minimal` | clang  | `thin`     |     **682.7 KB** |
| default          | zig cc   | —          |     869.0 KB |

LTO on top of `minimal` shaves another **~21 KB** (3%). Cheapest unclaimed
win; can be turned on in the Makefile any time without touching code.

`libzjs.a` archive size is ~1.3 MB at every tier — the archive contains
all symbols; the linker drops the gated ones at link-time via dead-strip,
which is why the binary shrinks but the archive doesn't.

### zig cc note

On an Apple host targeting Apple, `zig cc` produces a **slightly larger**
binary than Apple's own clang (869 KB vs 825 KB). Likely culprits: zig's
LLVM is a half-minor-version ahead of Apple's, with different default
unwind / pointer-auth metadata, and the SDK linker complains about
"object file was built for newer macOS version" warnings during the link
(zig defaults to a higher deployment target than the SDK ld expects).

This does NOT diminish zig's value for cross-compile (#187, #206): for
non-Apple targets zig brings musl libc, a single toolchain that produces
small static binaries, and `-target` cross-build for free. On-host, prefer
Apple clang for size; use zig for any other target.

## Where the bytes live (top 50 functions, default tier)

Aggregated by subsystem:

| Subsystem            | Bytes  | Notes |
| -------------------- | -----: | ----- |
| Compiler             | 53,660 | `compile_stmt` 11.8K + `compile_expr` 6.9K + dozens more |
| Regex (tre)          | 42,124 | bundled `tre_full.c`; sum across `tre_*` |
| Builtin registration | 35,628 | single function: `ctx_init_builtins` |
| Interpreter dispatch | 32,908 | `interpret_inner_full` — opcode handlers + super-instruction fusions |
| Parser               | 23,440 | `parse_*` family |
| Host built-ins       | 18,756 | `host_promise_any/all/race`, `host_url_to_string`, `host_string_replace`, etc. |
| Property IC          | 13,092 | `property_get` + `property_set` |
| JSON                 | 10,612 | parse + stringify |
| GC                   |  7,092 | `gc_mark_roots`, `gc_mark_cell_children` |
| AOT serializer       |  6,500 | top fns only — full subsystem is ~15 KB |
| Lexer                |  2,800 | only the top hot path here |
| Other                | 13,436 |   |

The top three single functions all sit above 30 KB each:

1. `ctx_init_builtins` — 35.6 KB. The proto-chain installer. Every
   `String.prototype.X` / `Array.prototype.X` / etc. wiring is here.
   Unavoidable but ripe for a *driven-by-table* refactor — replace the
   straight-line code with a `static const struct { atom, host_fn }[]`
   table that a tiny loop walks. Would likely cut this in half.

2. `interpret_inner_full` — 32.9 KB. The op-dispatch heart. Recent
   super-instruction fusions added ~3 KB; the Math fast paths another
   ~1 KB. Don't shrink this — it's load-bearing for perf.

3. `compile_stmt` — 11.8 KB. The bytecode-emit dispatcher. Same shape
   as the interpreter and equally load-bearing.

## Path to ~550 KB (the zapp budget)

Current minimal+LTO: **683 KB**. Need to drop ~133 KB to hit the budget.
The honest realistic next steps:

| Win                                          | Estimated | Effort |
| -------------------------------------------- | --------: | ------ |
| Enable LTO in Makefile by default            | already counted | trivial |
| `ZJS_NO_AOT` flag — drop the writer half     | 8–12 KB | small (1 raw{} gate around `aot_write_*`) |
| Table-drive `ctx_init_builtins`              | 12–18 KB | medium (mechanical refactor, no behavior change) |
| Lighter regex than tre                        | 25–35 KB | large (re2c / hand-rolled; affects spec compliance) |
| `ZJS_NO_JSON` (if embedder doesn't need it)   | 8–10 KB | small (same gate pattern) |
| `ZJS_NO_FETCH_HOST` (drop URL parser too)     | 8–12 KB | small |
| `ZJS_NO_REGEX` (drop RegExp + tre entirely)   | 45–55 KB | nuclear (spec-breaking; only for embedders that opt out) |

Without the regex-replacement (which is a real project), the available
opt-out wins on top of minimal are ~40 KB → **~640 KB**. Hitting 550 KB
genuinely requires a lighter regex.

## Generational GC sizing forecast

The young/old split is scaffolded but dormant. Enabling it requires:

- Age field already exists on cells (no struct change)
- Write barriers exist for the slow path already
- Add a minor-collect path: scan young region + remembered set
- Add the remembered set itself (small fixed-size hash or chunked list)

Code growth estimate: **5–15 KB** to the engine. Net binary impact will
be smaller because the new code reuses the existing mark/sweep machinery
for the major collection. Won't blow the budget.

## Recommendations

1. **Enable LTO in default Makefile.** ✓ Landed 2026-05-27 (`-flto=thin`
   on all engine objects; opt out with `ZJS_NO_LTO=1`).
2. **Add `ZJS_NO_AOT` flag.** ✓ Landed 2026-05-27 as `ZJS_NO_AOT_WRITER`
   (writer half only; reader stays so `.zbc` loading works at all tiers).
3. **Refactor `ctx_init_builtins` to be table-driven.** Still the largest
   single function in the engine (35.6 KB). Structured as a long sequence
   of repetitive `register(...)` calls. A driver loop over a const table
   should halve its size. Best remaining ROI for in-engine size wins —
   would land another 12-18 KB.
4. **Defer regex replacement** until after generational GC and the next
   conformance push. It's a multi-week project; current tre is correct
   and fast, just large.

## Path to 550 KB (zapp budget) — updated

After this pass, minimal-tier embedder is **665.9 KB**. Need ~115 KB to
hit 550 KB. Realistic remaining steps:

| Win                                | Est.       | Effort |
| ---------------------------------- | ---------: | ------ |
| Table-drive `ctx_init_builtins`    | 12-18 KB   | medium |
| `ZJS_NO_JSON` opt-out              |  8-10 KB   | small  |
| `ZJS_NO_FETCH_HOST` opt-out        |  8-12 KB   | small  |
| Lighter regex than tre             | 25-35 KB   | large  |
| `ZJS_NO_REGEX` (spec-breaking)     | 45-55 KB   | nuclear |

Without the regex-replacement, the available opt-out wins on top of
minimal are ~30-40 KB → **~630 KB**. Sub-550 KB still requires either
a lighter regex or the spec-breaking opt-out.
