# Perf snapshot — 2026-06-09 (`d2b81bc`)

Measured on Apple M4 Max, macOS. All numbers are startup-corrected body medians
(5 iters) from `python3 scripts/bench/run.py --compare`. Interactive reports:
`docs/perf/index.html` (zjs history) and `docs/perf/compare.html` (cross-engine).

Engines: zjs `d2b81bc` (interpreter; `zjs-jit` = opt-in ZJS_JIT build) ·
QuickJS-ng 0.14.0 · Hermes 0.12 (`-O`) · Static Hermes (`-O -exec`) ·
node v22.14.0 · bun 1.3.9 · deno 2.7.14 · boa.

## Headlines

| Comparison | Geomean | Wins |
|---|---|---|
| **zjs vs QuickJS-ng** | **1.32× faster** | 17/23 |
| zjs vs Hermes `-O` | 2.2× slower (0.46×) | 1/18 |
| zjs vs Static Hermes | 1.7× slower (0.58×) | 3/15 |
| zjs vs boa | 7.1× faster | 22/22 |
| zjs vs node/bun/deno (full JITs) | ~5–6× slower | — |
| zjs-jit vs zjs interpreter | 1.23× faster | 14/23 |

- **QuickJS: clearly ahead** — the jitless-vs-jitless peer comparison. Largest
  margins: object_alloc 2.6×, json_roundtrip 2.3×, func_loop 2.3×, int loops
  ~2.1×, splay 1.7×. Behind on: nbody 0.76×, fib 0.81×, closure_call 0.82×,
  mandelbrot 0.88×, method_call 0.88×, property_poly 0.86× — call-sequence and
  pure-float-loop shaped, the known next levers (JIT float specialization
  covers the float ones on JIT-capable platforms: mandelbrot jit 26.5ms ≈ 2.2×).
- **Hermes (the jitless North Star): ~2.2× ahead of us overall.** Closest:
  sieve ~1.0×, regex 1.3×, quicksort 1.4×, richards 1.8×, splay 1.8×. Widest:
  int_loop_big 4.8×, mandelbrot 4.2×, nbody 3.8×, obj_field 3.9× — Hermes's
  bytecode-level optimization (-O) + cheaper allocation. Caveat: hermes timer
  resolution is 1ms; sub-2ms readings are excluded from the geomean.
- node/bun/deno are full JITs — context, not the comparison class for a
  jitless-first engine.

## This perf arc (2026-06-05 `7725c32a` → 2026-06-09 `d2b81bc`)

Fast-define (`64742aa`), atom pointer-equality (`88c3463`), per-shape property
table (`745d412`), Op::InitObjData intern skip (`2c3aed8`). **Geomean −8.5%,
all 23 benches improved**:

| bench | pre-arc | now | Δ |
|---|---:|---:|---:|
| object_alloc | 10.51 | 8.11 | −22.8% |
| hash_count | 2.48 | 2.11 | −15.0% |
| splay | 179.20 | 155.06 | −13.5% |
| mandelbrot | 66.72 | 57.96 | −13.1% |
| property_poly | 7.98 | 7.02 | −12.0% |
| json_roundtrip | 13.36 | 11.87 | −11.2% |
| quicksort | 14.13 | 12.61 | −10.8% |
| nbody | 114.36 | 102.85 | −10.1% |
| closure_call | 6.70 | 6.09 | −9.1% |
| method_call | 7.27 | 6.61 | −9.1% |
| try_overhead | 3.13 | 2.85 | −8.9% |
| double_loop | 5.03 | 4.62 | −8.0% |
| string_concat | 0.13 | 0.12 | −6.3% |
| richards | 165.51 | 155.23 | −6.2% |
| sieve | 11.09 | 10.45 | −5.9% |
| int_loop_big | 91.35 | 87.23 | −4.5% |
| property_mono | 8.08 | 7.71 | −4.5% |
| fib_recursive | 137.75 | 132.20 | −4.0% |
| regex_match | 119.04 | 114.86 | −3.5% |
| int_loop | 8.86 | 8.65 | −2.4% |
| func_loop | 470.25 | 460.81 | −2.0% |
| array_iterate | 1.31 | 1.29 | −1.3% |
| **geomean** | | | **−8.5%** |

(ms, medians. Off-suite targeted wins not visible here: wide-object
construction −34%, megamorphic deep-shape reads −17%/−56% now depth-
independent, splay max GC pause −28% under opt-in ZJS_GEN_GC.)

## Standalone (zjs interpreter, ms)

array_iterate 1.29 · closure_call 6.09 · double_loop 4.62 · fib 132.2 ·
func_loop 460.8 · hash_count 2.11 · int_loop 8.65 · int_loop_big 87.2 ·
json_roundtrip 11.87 · mandelbrot 57.96 · method_call 6.61 · nbody 102.9 ·
obj_field 298.6 · object_alloc 8.11 · property_mono 7.71 · property_poly 7.02 ·
quicksort 12.61 · regex_match 114.9 · richards 155.2 · sieve 10.45 ·
splay 155.1 · string_concat 0.12 · try_overhead 2.85

## Where the remaining Hermes gap lives (from docs/perf-architecture-review.md)

1. Allocation throughput (1–3 mallocs/object vs bump-pointer) — T3.1, parked.
2. Bytecode-level optimization (-O does CSE/licm/inlining at compile time;
   zjs compiles naively) — unexplored tier.
3. Call sequence (fib/closure_call/method_call shaped) — partially T1.3-descoped,
   revisit with a call-focused profile.
